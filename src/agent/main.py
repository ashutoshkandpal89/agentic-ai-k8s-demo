"""
Agent Orchestrator — FastAPI + LangGraph
Receives tasks, enforces token budgets, dispatches to Redis queue,
tracks metrics via Prometheus + OpenTelemetry.
"""

import os, json, time, uuid, logging
from contextlib import asynccontextmanager
from typing import Optional

import redis.asyncio as aioredis
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, Gauge, make_asgi_app, CollectorRegistry
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

from orchestrator import AgentOrchestrator
from token_budget import TokenBudgetManager

logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}'
)
logger = logging.getLogger("agent-orchestrator")

# ── Config ────────────────────────────────────────────────────────────────────
REDIS_URL        = os.getenv("REDIS_URL",        "redis://redis:6379")
TASK_QUEUE       = os.getenv("TASK_QUEUE",       "task-queue")
RESULT_PREFIX    = os.getenv("RESULT_PREFIX",    "result:")
OTLP_ENDPOINT    = os.getenv("OTLP_ENDPOINT",    "http://otel-collector:4317")
MAX_TOKEN_BUDGET = int(os.getenv("MAX_TOKEN_BUDGET", "50000"))
MOCK_LLM         = os.getenv("MOCK_LLM",         "false").lower() == "true"

# ── Prometheus ────────────────────────────────────────────────────────────────
registry = CollectorRegistry()
task_submitted_total   = Counter("agent_tasks_submitted_total",       "Tasks submitted",           ["status"],              registry=registry)
task_latency           = Histogram("agent_task_latency_seconds",      "End-to-end task latency",   buckets=[0.5,1,2,5,10,30,60,120], registry=registry)
token_usage_total      = Counter("agent_token_usage_total",           "Total tokens consumed",     ["model","task_type"],   registry=registry)
llm_cost_usd           = Counter("agent_llm_cost_usd_total",          "Estimated LLM cost USD",    ["model"],               registry=registry)
queue_depth            = Gauge("agent_task_queue_depth",              "Task queue depth",                                   registry=registry)
token_budget_breaches  = Counter("agent_token_budget_breaches_total", "Budget rejections",                                  registry=registry)
active_tasks           = Gauge("agent_active_tasks",                  "Executing agent tasks",                              registry=registry)

# ── OTel ──────────────────────────────────────────────────────────────────────
def setup_tracing():
    provider = TracerProvider()
    try:
        exporter = OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True)
        provider.add_span_processor(BatchSpanProcessor(exporter))
    except Exception as e:
        logger.warning(f"OTLP unavailable: {e}")
    trace.set_tracer_provider(provider)
    return trace.get_tracer("agent-orchestrator")

tracer = setup_tracing()

# ── App lifespan ──────────────────────────────────────────────────────────────
redis_client:   Optional[aioredis.Redis]         = None
orchestrator:   Optional[AgentOrchestrator]       = None
budget_manager: Optional[TokenBudgetManager]      = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global redis_client, orchestrator, budget_manager
    redis_client   = aioredis.from_url(REDIS_URL, decode_responses=True)
    orchestrator   = AgentOrchestrator(redis_client, TASK_QUEUE, MOCK_LLM, tracer)
    budget_manager = TokenBudgetManager(redis_client, MAX_TOKEN_BUDGET)
    logger.info(f"Orchestrator started | redis={REDIS_URL} | mock={MOCK_LLM}")
    yield
    await redis_client.aclose()

app = FastAPI(title="AI Agent Orchestrator", version="1.0.0", lifespan=lifespan)
FastAPIInstrumentor.instrument_app(app)
app.mount("/metrics", make_asgi_app(registry=registry))

# ── Models ────────────────────────────────────────────────────────────────────
class TaskRequest(BaseModel):
    task:                   str   = Field(..., min_length=5, max_length=2000)
    token_budget:           int   = Field(default=2000, ge=100, le=MAX_TOKEN_BUDGET)
    priority:               str   = Field(default="normal", pattern="^(low|normal|high)$")
    task_type:              str   = Field(default="research")
    require_human_approval: bool  = Field(default=False)

class TaskResponse(BaseModel):
    task_id:         str
    status:          str
    queue_position:  int
    estimated_tokens: int
    message:         str

class TaskResult(BaseModel):
    task_id:          str
    status:           str
    result:           Optional[str]   = None
    tokens_used:      int             = 0
    cost_usd:         float           = 0.0
    latency_seconds:  float           = 0.0
    error:            Optional[str]   = None

# ── Routes ────────────────────────────────────────────────────────────────────
@app.get("/healthz")
async def healthz():
    return {"status": "ok", "service": "agent-orchestrator"}

@app.get("/readyz")
async def readyz():
    try:
        await redis_client.ping()
        return {"status": "ready"}
    except Exception as e:
        raise HTTPException(503, detail=f"Redis unavailable: {e}")

@app.post("/agent/run", response_model=TaskResponse)
async def run_agent_task(request: TaskRequest):
    task_id = str(uuid.uuid4())

    with tracer.start_as_current_span("agent.task.submit") as span:
        span.set_attribute("task.id",       task_id)
        span.set_attribute("task.type",     request.task_type)
        span.set_attribute("token.budget",  request.token_budget)

        budget_ok, reason = await budget_manager.check_budget(request.token_budget)
        if not budget_ok:
            token_budget_breaches.inc()
            task_submitted_total.labels(status="rejected_budget").inc()
            raise HTTPException(429, detail={"error": "TOKEN_BUDGET_EXCEEDED", "message": reason, "task_id": task_id})

        payload = {
            "task_id": task_id, "task": request.task,
            "token_budget": request.token_budget, "priority": request.priority,
            "task_type": request.task_type,
            "require_human_approval": request.require_human_approval,
            "submitted_at": time.time(),
        }

        if request.priority == "high":
            await redis_client.lpush(TASK_QUEUE, json.dumps(payload))
        else:
            await redis_client.rpush(TASK_QUEUE, json.dumps(payload))

        depth = await redis_client.llen(TASK_QUEUE)
        queue_depth.set(depth)
        task_submitted_total.labels(status="accepted").inc()

        return TaskResponse(
            task_id=task_id, status="queued",
            queue_position=depth, estimated_tokens=request.token_budget,
            message=f"Task queued. Position: {depth}. Workers auto-scale if needed."
        )

@app.get("/agent/result/{task_id}", response_model=TaskResult)
async def get_task_result(task_id: str):
    raw = await redis_client.get(f"{RESULT_PREFIX}{task_id}")
    if not raw:
        return TaskResult(task_id=task_id, status="pending")
    data = json.loads(raw)
    if data.get("status") == "completed":
        tokens = data.get("tokens_used", 0)
        model  = data.get("model", "unknown")
        token_usage_total.labels(model=model, task_type=data.get("task_type","unknown")).inc(tokens)
        llm_cost_usd.labels(model=model).inc(tokens * 0.000002)
    return TaskResult(**{k: v for k, v in data.items() if k in TaskResult.model_fields})

@app.get("/agent/queue/stats")
async def queue_stats():
    depth  = await redis_client.llen(TASK_QUEUE)
    budget = await budget_manager.get_budget_status()
    queue_depth.set(depth)
    return {"queue_depth": depth, "budget_status": budget, "mock_llm": MOCK_LLM}

@app.post("/agent/queue/drain")
async def drain_queue():
    count = await redis_client.llen(TASK_QUEUE)
    await redis_client.delete(TASK_QUEUE)
    logger.warning(f"Queue drained. {count} tasks discarded.")
    return {"drained": count, "message": "kubectl delete namespace moment — all tasks gone"}

@app.get("/")
async def root():
    return {"service": "ai-agent-orchestrator", "version": "1.0.0", "docs": "/docs", "metrics": "/metrics"}
