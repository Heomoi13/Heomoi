from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from .config import Config
from .gateway import GatewayError, GatewayTransientError, chat_completion
from .ledger import append_entry, read_context
from .planner import Done, Escalate, Planner, Step
from .protocol import Footer, parse_footer, wrap_prompt
from .providers import ProviderStatus, check_providers, is_available


# ── Result types ──────────────────────────────────────────────────────────────

@dataclass
class StepResult:
    model: str
    text: str
    footer: Footer
    error: Optional[str] = None


@dataclass
class RunResult:
    status: str  # "done" | "escalated"
    history: list[StepResult]
    summary: Optional[str] = None            # populated when status == "done"
    escalation_reason: Optional[str] = None  # populated when status == "escalated"


# ── Orchestrator ──────────────────────────────────────────────────────────────

class Orchestrator:
    def __init__(self, workspace: str, config: Config) -> None:
        self.workspace = str(Path(workspace).resolve())
        self.config = config

    def _timeout_for(self, model: str) -> int:
        if model.lower().startswith("gemini"):
            return self.config.gemini_timeout
        return self.config.default_timeout

    def _execute_step(self, step: Step) -> StepResult:
        """Raw gateway call for one Step. Caller must have already verified availability."""
        ledger_ctx = read_context(self.workspace)
        messages = wrap_prompt(step.prompt, ledger_ctx, step.model)
        timeout = self._timeout_for(step.model)

        try:
            text = chat_completion(
                config=self.config,
                model=step.model,
                messages=messages,
                workspace=self.workspace,
                timeout=timeout,
            )
        except (GatewayError, GatewayTransientError) as exc:
            footer = Footer(status="blocked", files_changed=[], next=None)
            return StepResult(model=step.model, text="", footer=footer, error=str(exc))

        footer = parse_footer(text)
        append_entry(self.workspace, step.model, step.prompt[:120], text)
        return StepResult(model=step.model, text=text, footer=footer)

    # ── Public library API ────────────────────────────────────────────────────

    def run(self, planner: Planner) -> RunResult:
        """Run the observe-replan loop. Returns pure data; no stdout.

        Safety guardrails (all deterministic, in engine — no LLM):
          - max_steps: cap on loop iterations
          - max_delegations: cap on total gateway calls (quota guard)
          - oscillation_limit: consecutive identical Step decisions → escalate
          - needs_info_limit: consecutive needs-info footer results → escalate
        """
        providers = check_providers(self.config)
        history: list[StepResult] = []

        step_count = 0
        delegation_count = 0
        consecutive_needs_info = 0
        consecutive_oscillation = 0
        last_step_key: Optional[str] = None

        while True:
            # ── Safety: max_steps ─────────────────────────────────────────────
            if step_count >= self.config.max_steps:
                return RunResult(
                    status="escalated",
                    history=history,
                    escalation_reason="max_steps reached",
                )

            # ── Ask planner for next decision ─────────────────────────────────
            ledger_ctx = read_context(self.workspace)
            decision = planner.next_step(ledger_ctx, history)

            if isinstance(decision, Done):
                return RunResult(
                    status="done",
                    history=history,
                    summary=decision.summary,
                )

            if isinstance(decision, Escalate):
                return RunResult(
                    status="escalated",
                    history=history,
                    escalation_reason=decision.reason,
                )

            # ── It's a Step ───────────────────────────────────────────────────
            step_count += 1

            # Oscillation: same (model, prompt) N times in a row
            step_key = f"{decision.model}::{decision.prompt}"
            if step_key == last_step_key:
                consecutive_oscillation += 1
            else:
                consecutive_oscillation = 1
            last_step_key = step_key

            if consecutive_oscillation >= self.config.oscillation_limit:
                return RunResult(
                    status="escalated",
                    history=history,
                    escalation_reason="planner oscillating",
                )

            # Safety: max_delegations (quota guard)
            if delegation_count >= self.config.max_delegations:
                return RunResult(
                    status="escalated",
                    history=history,
                    escalation_reason="max_delegations reached",
                )

            # Provider availability — engine NEVER picks a substitute
            if not is_available(providers, decision.model):
                return RunResult(
                    status="escalated",
                    history=history,
                    escalation_reason=f"provider '{decision.model}' not available",
                )

            delegation_count += 1
            result = self._execute_step(decision)
            history.append(result)

            # Safety: repeated needs-info
            if result.footer.status == "needs-info":
                consecutive_needs_info += 1
            else:
                consecutive_needs_info = 0

            if consecutive_needs_info >= self.config.needs_info_limit:
                return RunResult(
                    status="escalated",
                    history=history,
                    escalation_reason="repeated needs-info",
                )

    def run_step(
        self,
        model: str,
        prompt: str,
        providers: Optional[list[ProviderStatus]] = None,
    ) -> StepResult:
        """Execute exactly one step. Used by CLI 'step' command and unit tests."""
        if providers is None:
            providers = check_providers(self.config)
        if not is_available(providers, model):
            footer = Footer(status="blocked", files_changed=[], next=None)
            return StepResult(
                model=model,
                text="",
                footer=footer,
                error=f"Provider '{model}' not available",
            )
        return self._execute_step(Step(model=model, prompt=prompt))

    def run_step_multi(
        self,
        models: list[str],
        prompt: str,
        providers: Optional[list[ProviderStatus]] = None,
    ) -> list[StepResult]:
        """Same prompt to multiple models (review/cross-check). Capped by max_parallel."""
        if providers is None:
            providers = check_providers(self.config)

        cap = max(1, self.config.max_parallel)

        if cap == 1 or len(models) == 1:
            return [self.run_step(m, prompt, providers) for m in models]

        with ThreadPoolExecutor(max_workers=cap) as pool:
            futures = {pool.submit(self.run_step, m, prompt, providers): m for m in models}
            return [fut.result() for fut in as_completed(futures)]
