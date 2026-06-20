from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, runtime_checkable


# ── PlanDecision types ────────────────────────────────────────────────────────

@dataclass
class Step:
    """Delegate this step to a worker model."""
    model: str
    prompt: str


@dataclass
class Done:
    """Plan complete — clean exit."""
    summary: str


@dataclass
class Escalate:
    """Planner cannot decide; hand control back to caller (Hermes/user)."""
    reason: str


PlanDecision = Step | Done | Escalate


# ── Planner interface ─────────────────────────────────────────────────────────

@runtime_checkable
class Planner(Protocol):
    """Observer-replan interface. Engine calls this every loop iteration."""

    def next_step(self, ledger_context: str, history: list) -> PlanDecision:
        """Given current ledger context and step history, return next decision."""
        ...


# ── StaticPlanner — ships with this project ───────────────────────────────────

class StaticPlanner:
    """Executes a fixed ordered list of Step decisions, then Done.

    Equivalent to "Hermes handed us a full plan upfront". The most common
    CLI use case; no model call required.
    """

    def __init__(self, steps: list[Step]) -> None:
        self._steps = list(steps)
        self._idx = 0

    def next_step(self, ledger_context: str, history: list) -> PlanDecision:
        if self._idx >= len(self._steps):
            return Done(summary=f"Completed {len(self._steps)} step(s)")
        decision = self._steps[self._idx]
        self._idx += 1
        return decision
