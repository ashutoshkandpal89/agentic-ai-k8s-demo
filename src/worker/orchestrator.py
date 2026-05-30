"""
Agent Orchestrator — LangGraph-based agent workflow.
Implements: plan → tool_call → reflect → respond
with token tracking and span propagation.
"""

import json
import time
import logging
import asyncio
from typing import TypedDict, Annotated
import operator

import redis.asyncio as aioredis
from opentelemetry import trace

logger = logging.getLogger("orchestrator")


class AgentState(TypedDict):
    task_id:      str
    task:         str
    task_type:    str
    token_budget: int
    tokens_used:  int
    messages:     Annotated[list, operator.add]
    tool_calls:   Annotated[list, operator.add]
    result:       str
    status:       str
    error:        str


TOOLS = {
    "web_search":   {"description": "Search the web for information",      "cost_tokens": 200},
    "summarize":    {"description": "Summarize a piece of text",            "cost_tokens": 150},
    "compare":      {"description": "Compare multiple items on criteria",   "cost_tokens": 300},
    "write_report": {"description": "Write a structured report",            "cost_tokens": 500},
}


class AgentOrchestrator:
    def __init__(self, redis_client: aioredis.Redis, queue_name: str, mock_llm: bool, tracer):
        self.redis   = redis_client
        self.queue   = queue_name
        self.mock    = mock_llm
        self.tracer  = tracer
        logger.info(f"AgentOrchestrator initialized (mock_llm={mock_llm})")

    async def run(self, task_payload: dict) -> dict:
        task_id      = task_payload["task_id"]
        task         = task_payload["task"]
        token_budget = task_payload.get("token_budget", 2000)
        task_type    = task_payload.get("task_type", "research")
        start_time   = time.time()

        with self.tracer.start_as_current_span("agent.workflow.execute") as span:
            span.set_attribute("task.id",      task_id)
            span.set_attribute("task.type",    task_type)
            span.set_attribute("token.budget", token_budget)

            state = AgentState(
                task_id=task_id, task=task, task_type=task_type,
                token_budget=token_budget, tokens_used=0,
                messages=[], tool_calls=[],
                result="", status="running", error=""
            )

            try:
                state = await self._plan_node(state, span)
                if state["status"] == "budget_exceeded":
                    raise RuntimeError("Token budget exceeded during planning")

                state = await self._tool_execution_node(state, span)
                if state["status"] == "budget_exceeded":
                    raise RuntimeError("Token budget exceeded during tool execution")

                state = await self._synthesize_node(state, span)

                latency = time.time() - start_time
                span.set_attribute("tokens.used",      state["tokens_used"])
                span.set_attribute("task.latency_sec", round(latency, 2))

                return {
                    "task_id":          task_id,
                    "status":           "completed",
                    "result":           state["result"],
                    "tokens_used":      state["tokens_used"],
                    "cost_usd":         state["tokens_used"] * 0.000002,
                    "latency_seconds":  round(latency, 2),
                    "tool_calls":       state["tool_calls"],
                    "model":            "llama3.2" if not self.mock else "mock",
                    "task_type":        task_type,
                }

            except Exception as e:
                latency = time.time() - start_time
                logger.error(f"Task {task_id} failed: {e}")
                span.record_exception(e)
                return {
                    "task_id":         task_id,
                    "status":          "failed",
                    "error":           str(e),
                    "tokens_used":     state.get("tokens_used", 0),
                    "cost_usd":        0.0,
                    "latency_seconds": round(latency, 2),
                    "model":           "unknown",
                    "task_type":       task_type,
                }

    async def _plan_node(self, state: AgentState, parent_span) -> AgentState:
        with self.tracer.start_as_current_span("agent.node.plan",
                context=trace.set_span_in_context(parent_span)) as span:
            planning_tokens = 300
            if state["tokens_used"] + planning_tokens > state["token_budget"]:
                state["status"] = "budget_exceeded"
                return state

            plan = self._mock_plan(state["task"], state["task_type"]) if self.mock \
                   else await self._llm_plan(state["task"], state["task_type"])

            state["tokens_used"] += planning_tokens
            state["messages"].append({"role": "assistant", "content": f"Plan: {plan}"})
            span.set_attribute("tools.planned", str(plan.get("tools", [])))
            state["_plan"] = plan
            return state

    async def _tool_execution_node(self, state: AgentState, parent_span) -> AgentState:
        with self.tracer.start_as_current_span("agent.node.tool_execution",
                context=trace.set_span_in_context(parent_span)):
            plan    = state.get("_plan", {})
            tools   = plan.get("tools", ["summarize"])
            results = []

            for tool_name in tools:
                tool_cost = TOOLS.get(tool_name, {}).get("cost_tokens", 200)
                with self.tracer.start_as_current_span(f"agent.tool.{tool_name}") as ts:
                    ts.set_attribute("tool.name",        tool_name)
                    ts.set_attribute("tool.cost_tokens", tool_cost)

                    if state["tokens_used"] + tool_cost > state["token_budget"]:
                        logger.warning(f"[{state['task_id']}] Budget exceeded at tool '{tool_name}'")
                        state["status"] = "budget_exceeded"
                        state["result"] = "\n".join(results) or "Partial result: budget exceeded"
                        return state

                    result = await self._execute_tool(tool_name, state["task"], state["task_type"])
                    state["tokens_used"] += tool_cost
                    results.append(f"[{tool_name}]: {result}")
                    state["tool_calls"].append({
                        "tool": tool_name, "tokens_used": tool_cost,
                        "result_length": len(result)
                    })
                    ts.set_attribute("tool.success", True)

            state["messages"].append({"role": "tool", "content": "\n".join(results)})
            state["_tool_results"] = results
            return state

    async def _synthesize_node(self, state: AgentState, parent_span) -> AgentState:
        with self.tracer.start_as_current_span("agent.node.synthesize",
                context=trace.set_span_in_context(parent_span)) as span:
            synthesis_tokens = 400
            span.set_attribute("synthesis.tokens", synthesis_tokens)

            if state["tokens_used"] + synthesis_tokens > state["token_budget"]:
                state["status"] = "budget_exceeded"
                state["result"] = (state.get("_tool_results") or ["No result"])[0]
                return state

            tool_results = state.get("_tool_results", [])
            result = self._mock_synthesis(state["task"], tool_results) if self.mock \
                     else await self._llm_synthesize(state["task"], tool_results)

            state["tokens_used"] += synthesis_tokens
            state["result"] = result
            state["status"] = "completed"
            return state

    async def _llm_plan(self, task: str, task_type: str) -> dict:
        try:
            import httpx
            prompt = (
                f"You are a planning agent. Given this task, decide which tools to use.\n"
                f"Available tools: {list(TOOLS.keys())}\n"
                f"Task: {task}\n"
                f"Respond ONLY in JSON: {{\"tools\": [\"tool1\"], \"reasoning\": \"...\"}}"
            )
            async with httpx.AsyncClient(timeout=30.0) as client:
                resp = await client.post("http://ollama:11434/api/generate",
                    json={"model": "llama3.2:1b", "prompt": prompt, "stream": False})
                resp.raise_for_status()
                import re
                text  = resp.json().get("response", "")
                match = re.search(r'\{.*\}', text, re.DOTALL)
                if match:
                    return json.loads(match.group())
        except Exception as e:
            logger.warning(f"Ollama planning failed, using mock: {e}")
        return self._mock_plan(task, task_type)

    async def _llm_synthesize(self, task: str, tool_results: list) -> str:
        try:
            import httpx
            context = "\n".join(tool_results[:3])
            prompt  = (
                f"Synthesize these research results into a concise answer.\n"
                f"Task: {task}\nResults:\n{context}\n"
                f"Write a clear, structured 3-5 sentence response."
            )
            async with httpx.AsyncClient(timeout=60.0) as client:
                resp = await client.post("http://ollama:11434/api/generate",
                    json={"model": "llama3.2:1b", "prompt": prompt, "stream": False})
                resp.raise_for_status()
                return resp.json().get("response", "").strip()
        except Exception as e:
            logger.warning(f"Ollama synthesis failed, using mock: {e}")
            return self._mock_synthesis(task, tool_results)

    async def _execute_tool(self, tool_name: str, task: str, task_type: str) -> str:
        await asyncio.sleep(0.1)
        outputs = {
            "web_search":   f"Search results for '{task[:50]}': Found 3 relevant documents.",
            "summarize":    f"Summary: {task_type} work on '{task[:50]}'. Key points: scalability, cost, governance.",
            "compare":      f"Comparison: AWS vs GCP vs Azure on K8s — each has distinct AI workload advantages.",
            "write_report": f"Report: 'Analysis of {task[:50]}' — architecture, cost, operational recommendations.",
        }
        return outputs.get(tool_name, f"Tool '{tool_name}' executed successfully.")

    def _mock_plan(self, task: str, task_type: str) -> dict:
        plans = {
            "research": {"tools": ["web_search", "summarize", "write_report"], "reasoning": "Research needs search + summarization"},
            "compare":  {"tools": ["compare", "write_report"],                 "reasoning": "Comparison needs structured analysis"},
            "default":  {"tools": ["summarize"],                               "reasoning": "Simple summarization"},
        }
        return plans.get(task_type, plans["default"])

    def _mock_synthesis(self, task: str, tool_results: list) -> str:
        return (
            f"[MOCK] Completed analysis of: '{task[:100]}'.\n"
            f"Executed {len(tool_results)} tool call(s).\n"
            f"Finding: All major cloud providers offer managed Kubernetes with AI/ML capabilities. "
            f"Recommendation: Choose based on existing cloud investment and GPU availability.\n"
            f"(Mock output — set MOCK_LLM=false and deploy Ollama for real LLM responses)"
        )
