"""
Token Budget Manager
Enforces per-namespace and global token budgets using Redis.
This is the "circuit breaker for cost" — the thing that saves you from the $12k bill.
"""

import time
import logging
from typing import Tuple

import redis.asyncio as aioredis

logger = logging.getLogger("token-budget")

BUDGET_KEY        = "token:budget:used"
BUDGET_WINDOW_KEY = "token:budget:window_start"
WINDOW_SECONDS    = 3600  # 1-hour rolling window


class TokenBudgetManager:
    def __init__(self, redis_client: aioredis.Redis, max_tokens: int):
        self.redis      = redis_client
        self.max_tokens = max_tokens
        logger.info(f"TokenBudgetManager: max={max_tokens} tokens per {WINDOW_SECONDS}s window")

    async def check_budget(self, requested_tokens: int) -> Tuple[bool, str]:
        """Check if we have budget remaining. Returns (allowed, reason)."""
        window_start = await self.redis.get(BUDGET_WINDOW_KEY)
        now = time.time()

        if not window_start or (now - float(window_start)) > WINDOW_SECONDS:
            await self.redis.set(BUDGET_WINDOW_KEY, now)
            await self.redis.set(BUDGET_KEY, 0)
            logger.info("Token budget window reset")

        current_used = int(await self.redis.get(BUDGET_KEY) or 0)
        projected    = current_used + requested_tokens

        if projected > self.max_tokens:
            remaining = max(0, self.max_tokens - current_used)
            reason = (
                f"Token budget exhausted. "
                f"Used: {current_used}/{self.max_tokens}. "
                f"Requested: {requested_tokens}. "
                f"Remaining: {remaining}. "
                f"Window resets in {int(WINDOW_SECONDS - (now - float(window_start or now)))}s."
            )
            logger.warning(f"Budget check FAILED: {reason}")
            return False, reason

        await self.redis.incrby(BUDGET_KEY, requested_tokens)
        logger.debug(f"Budget reserved: {requested_tokens} tokens. Total: {projected}/{self.max_tokens}")
        return True, "ok"

    async def record_actual_usage(self, reserved: int, actual: int):
        """Correct the budget after actual LLM call."""
        delta = reserved - actual
        if delta > 0:
            await self.redis.decrby(BUDGET_KEY, delta)

    async def get_budget_status(self) -> dict:
        current_used = int(await self.redis.get(BUDGET_KEY) or 0)
        window_start = await self.redis.get(BUDGET_WINDOW_KEY)
        now = time.time()
        window_elapsed = int(now - float(window_start or now))
        return {
            "max_tokens":        self.max_tokens,
            "used_tokens":       current_used,
            "remaining_tokens":  max(0, self.max_tokens - current_used),
            "utilization_pct":   round(current_used / self.max_tokens * 100, 1),
            "window_elapsed_s":  window_elapsed,
            "window_remaining_s": max(0, WINDOW_SECONDS - window_elapsed),
            "alert":    current_used > self.max_tokens * 0.7,
            "critical": current_used > self.max_tokens * 0.9,
        }

    async def force_reset(self):
        """Emergency reset."""
        await self.redis.set(BUDGET_KEY, 0)
        await self.redis.set(BUDGET_WINDOW_KEY, time.time())
        logger.warning("Token budget FORCE RESET")
