"""
AI Worker — polls Redis task queue, executes agent workflows.
This is the pod KEDA scales up and down.
One worker = one concurrent agent execution.
"""

import os, json, time, logging, asyncio, signal
from typing import Optional

import redis.asyncio as aioredis
from prometheus_client import Counter, Histogram, Gauge, start_http_server
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","worker":"%(name)s","msg":"%(message)s"}'
)
logger = logging.getLogger("ai-worker")

# ── Config ────────────────────────────────────────────────────────────────────
REDIS_URL        = os.getenv("REDIS_URL",        "redis://redis:6379")
TASK_QUEUE       = os.getenv("TASK_QUEUE",       "task-queue")
RESULT_PREFIX    = os.getenv("RESULT_PREFIX",    "result:")
RESULT_TTL       = int(os.getenv("RESULT_TTL",   "3600"))
OTLP_ENDPOINT    = os.getenv("OTLP_ENDPOINT",    "http://otel-collector:4317")
WORKER_ID        = os.getenv("HOSTNAME",          "worker-local")
MOCK_LLM         = os.getenv("MOCK_LLM",         "false").lower() == "true"
METRICS_PORT     = int(os.getenv("METRICS_PORT", "9090"))
POLL_TIMEOUT_SEC = int(os.getenv("POLL_TIMEOUT", "5"))

# ── Metrics ───────────────────────────────────────────────────────────────────
tasks_processed = Counter("worker_tasks_processed_total", "Tasks processed",   ["status","worker_id"])
task_latency    = Histogram("worker_task_latency_seconds", "Task duration",     ["worker_id"],
                            buckets=[0.5,1,2,5,10,30,60,120,300])
tokens_consumed = Counter("worker_tokens_consumed_total",  "Tokens consumed",   ["model","worker_id"])
worker_idle     = Gauge("worker_idle",                     "1=idle 0=busy",     ["worker_id"])

# ── OTel ──────────────────────────────────────────────────────────────────────
def setup_tracing():
    provider = TracerProvider()
    try:
        exporter = OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True)
        provider.add_span_processor(BatchSpanProcessor(exporter))
    except Exception as e:
        logger.warning(f"OTel unavailable: {e}")
    trace.set_tracer_provider(provider)
    return trace.get_tracer("ai-worker")

tracer = setup_tracing()


class AIWorker:
    def __init__(self):
        self.redis:   Optional[aioredis.Redis] = None
        self.running  = True
        self.worker_id = WORKER_ID
        worker_idle.labels(worker_id=self.worker_id).set(1)

    async def start(self):
        self.redis = aioredis.from_url(REDIS_URL, decode_responses=True)
        logger.info(f"Worker {self.worker_id} started | queue={TASK_QUEUE} | mock={MOCK_LLM}")
        start_http_server(METRICS_PORT)
        logger.info(f"Metrics server :{METRICS_PORT}")
        await self.poll_loop()

    async def poll_loop(self):
        logger.info(f"Worker {self.worker_id} polling {TASK_QUEUE}...")
        while self.running:
            try:
                result = await self.redis.brpop(TASK_QUEUE, timeout=POLL_TIMEOUT_SEC)
                if result is None:
                    continue
                _, raw_task = result
                task_payload = json.loads(raw_task)
                await self.execute_task(task_payload)
            except aioredis.RedisError as e:
                logger.error(f"Redis error: {e}. Retrying in 2s...")
                await asyncio.sleep(2)
            except json.JSONDecodeError as e:
                logger.error(f"Invalid task JSON: {e}")
            except Exception as e:
                logger.error(f"Unexpected error: {e}", exc_info=True)
                await asyncio.sleep(1)

    async def execute_task(self, task_payload: dict):
        task_id = task_payload.get("task_id", "unknown")
        start   = time.time()
        worker_idle.labels(worker_id=self.worker_id).set(0)

        with tracer.start_as_current_span("worker.task.execute") as span:
            span.set_attribute("task.id",      task_id)
            span.set_attribute("worker.id",    self.worker_id)
            span.set_attribute("task.type",    task_payload.get("task_type","unknown"))
            span.set_attribute("token.budget", task_payload.get("token_budget", 0))

            logger.info(f"Executing task {task_id}: {task_payload.get('task','')[:80]}...")

            try:
                from orchestrator import AgentOrchestrator
                orch   = AgentOrchestrator(self.redis, TASK_QUEUE, MOCK_LLM, tracer)
                result = await orch.run(task_payload)
                latency = time.time() - start
                result["worker_id"]    = self.worker_id
                result["completed_at"] = time.time()

                result_key = f"{RESULT_PREFIX}{task_id}"
                await self.redis.setex(result_key, RESULT_TTL, json.dumps(result))

                tasks_processed.labels(status=result["status"], worker_id=self.worker_id).inc()
                task_latency.labels(worker_id=self.worker_id).observe(latency)
                tokens_consumed.labels(model=result.get("model","unknown"), worker_id=self.worker_id).inc(
                    result.get("tokens_used", 0)
                )
                span.set_attribute("task.status",  result["status"])
                span.set_attribute("tokens.used",  result.get("tokens_used",0))
                span.set_attribute("latency.sec",  round(latency,2))
                logger.info(f"Task {task_id} {result['status']} in {latency:.2f}s ({result.get('tokens_used',0)} tokens)")

            except Exception as e:
                latency = time.time() - start
                error_result = {
                    "task_id": task_id, "status": "failed", "error": str(e),
                    "tokens_used": 0, "cost_usd": 0.0,
                    "latency_seconds": round(latency,2), "worker_id": self.worker_id,
                }
                await self.redis.setex(f"{RESULT_PREFIX}{task_id}", RESULT_TTL, json.dumps(error_result))
                tasks_processed.labels(status="failed", worker_id=self.worker_id).inc()
                span.record_exception(e)
                logger.error(f"Task {task_id} failed: {e}", exc_info=True)

            finally:
                worker_idle.labels(worker_id=self.worker_id).set(1)

    def stop(self):
        logger.info(f"Worker {self.worker_id} shutting down gracefully...")
        self.running = False


async def main():
    worker = AIWorker()

    def handle_sigterm(*_):
        logger.info("SIGTERM received — graceful shutdown")
        worker.stop()

    signal.signal(signal.SIGTERM, handle_sigterm)
    signal.signal(signal.SIGINT,  handle_sigterm)

    await worker.start()
    if worker.redis:
        await worker.redis.aclose()
    logger.info("Worker shutdown complete")


if __name__ == "__main__":
    asyncio.run(main())
