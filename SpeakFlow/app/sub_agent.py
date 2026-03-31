"""Sub-agent concurrency system inspired by Claude Code's AgentTool.

Supports splitting complex tasks into parallel sub-tasks, each processed
by an independent LLM call, then aggregating results.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

from app.config import settings
from app.services.openai_service import client

logger = logging.getLogger(__name__)

MAX_CONCURRENT_AGENTS = 5
SUB_AGENT_TIMEOUT = 60  # seconds per sub-agent


class SubAgentTask:
    """A single sub-agent task definition."""

    def __init__(
        self,
        task_id: str,
        prompt: str,
        *,
        system_prompt: str | None = None,
        tools: list[dict[str, Any]] | None = None,
    ):
        self.task_id = task_id
        self.prompt = prompt
        self.system_prompt = system_prompt
        self.tools = tools
        self.result: str | None = None
        self.error: str | None = None
        self.duration_ms: int = 0


class SubAgentResult:
    """Aggregated result from all sub-agents."""

    def __init__(self, tasks: list[SubAgentTask], total_ms: int):
        self.tasks = tasks
        self.total_ms = total_ms

    @property
    def all_succeeded(self) -> bool:
        return all(t.error is None for t in self.tasks)

    @property
    def results(self) -> dict[str, str | None]:
        return {t.task_id: t.result for t in self.tasks}

    @property
    def errors(self) -> dict[str, str | None]:
        return {t.task_id: t.error for t in self.tasks if t.error}

    def to_summary(self) -> str:
        """Format results as a summary string suitable for LLM consumption."""
        parts = []
        for t in self.tasks:
            if t.error:
                parts.append(f"[{t.task_id}] ERROR: {t.error}")
            else:
                parts.append(f"[{t.task_id}] {t.result}")
        return "\n\n---\n\n".join(parts)


async def _execute_single_agent(task: SubAgentTask) -> SubAgentTask:
    """Execute a single sub-agent LLM call."""
    start = time.monotonic()
    messages: list[dict[str, Any]] = []
    if task.system_prompt:
        messages.append({"role": "system", "content": task.system_prompt})
    messages.append({"role": "user", "content": task.prompt})

    kwargs: dict[str, Any] = {
        "model": settings.gpt_model,
        "messages": messages,
        "max_completion_tokens": settings.gpt_max_tokens,
    }
    if task.tools:
        kwargs["tools"] = task.tools

    try:
        response = await asyncio.wait_for(
            client.chat.completions.create(**kwargs),
            timeout=SUB_AGENT_TIMEOUT,
        )
        if response.choices:
            task.result = response.choices[0].message.content or ""
        else:
            task.error = "LLM returned empty choices"
    except asyncio.TimeoutError:
        task.error = f"Sub-agent timed out after {SUB_AGENT_TIMEOUT}s"
    except Exception as e:
        task.error = str(e)

    task.duration_ms = int((time.monotonic() - start) * 1000)
    logger.info(
        "Sub-agent completed: id=%s ok=%s duration=%dms",
        task.task_id, task.error is None, task.duration_ms,
    )
    return task


async def run_sub_agents(
    tasks: list[SubAgentTask],
    *,
    max_concurrent: int = MAX_CONCURRENT_AGENTS,
) -> SubAgentResult:
    """Run multiple sub-agent tasks concurrently with a concurrency limit.

    Args:
        tasks: List of SubAgentTask definitions.
        max_concurrent: Maximum number of concurrent LLM calls.

    Returns:
        SubAgentResult with all task outcomes.
    """
    if not tasks:
        return SubAgentResult(tasks=[], total_ms=0)

    if len(tasks) > max_concurrent:
        logger.warning(
            "Sub-agent count %d exceeds max_concurrent %d, excess will queue",
            len(tasks), max_concurrent,
        )

    start = time.monotonic()
    semaphore = asyncio.Semaphore(max_concurrent)

    async def _guarded(task: SubAgentTask) -> SubAgentTask:
        async with semaphore:
            return await _execute_single_agent(task)

    completed = await asyncio.gather(*[_guarded(t) for t in tasks])
    total_ms = int((time.monotonic() - start) * 1000)

    logger.info(
        "Sub-agents finished: total=%d succeeded=%d failed=%d total_ms=%d",
        len(completed),
        sum(1 for t in completed if t.error is None),
        sum(1 for t in completed if t.error is not None),
        total_ms,
    )
    return SubAgentResult(tasks=list(completed), total_ms=total_ms)


def create_decomposition_prompt(user_request: str, num_subtasks: int) -> str:
    """Create a prompt that asks the LLM to decompose a complex task."""
    return f"""Analyze the following user request and break it down into {num_subtasks} independent sub-tasks that can be executed in parallel.

User request: {user_request}

For each sub-task, provide:
1. A unique task_id (short, descriptive)
2. A clear, self-contained prompt that can be executed independently

Format your response as JSON:
{{
  "subtasks": [
    {{"task_id": "...", "prompt": "..."}},
    ...
  ]
}}

Rules:
- Each sub-task must be independent (no dependencies between them)
- Each sub-task prompt must contain all necessary context
- Keep sub-tasks focused and specific
- If the request cannot be parallelized, return a single sub-task"""
