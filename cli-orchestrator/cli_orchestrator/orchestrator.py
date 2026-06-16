from __future__ import annotations

import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from .config import Config, load_config
from .gateway import GatewayError, GatewayTransientError, chat_completion
from .ledger import append_entry, read_context
from .protocol import Footer, parse_footer, wrap_prompt
from .providers import ProviderStatus, check_providers, is_available


@dataclass
class StepResult:
    model: str
    text: str
    footer: Footer
    error: Optional[str] = None


@dataclass
class PlanStep:
    model: str
    prompt: str


class Orchestrator:
    def __init__(self, workspace: str, config: Config):
        self.workspace = str(Path(workspace).resolve())
        self.config = config

    def _timeout_for(self, model: str) -> int:
        if model.lower().startswith("gemini"):
            return self.config.gemini_timeout
        return self.config.default_timeout

    def run_step(
        self,
        model: str,
        prompt: str,
        providers: Optional[list[ProviderStatus]] = None,
    ) -> StepResult:
        """Execute a single step against one model. Returns StepResult (no stdout)."""
        if providers is None:
            providers = check_providers(self.config)

        if not is_available(providers, model):
            reason = f"Provider '{model}' is not available"
            footer = Footer(status="blocked", files_changed=[], next=None)
            return StepResult(model=model, text="", footer=footer, error=reason)

        ledger_context = read_context(self.workspace)
        messages = wrap_prompt(prompt, ledger_context, model)
        timeout = self._timeout_for(model)

        try:
            text = chat_completion(
                config=self.config,
                model=model,
                messages=messages,
                workspace=self.workspace,
                timeout=timeout,
            )
        except (GatewayError, GatewayTransientError) as exc:
            footer = Footer(status="blocked", files_changed=[], next=None)
            return StepResult(model=model, text="", footer=footer, error=str(exc))

        footer = parse_footer(text)
        append_entry(self.workspace, model, prompt[:120], text)
        return StepResult(model=model, text=text, footer=footer)

    def run_step_multi(
        self,
        models: list[str],
        prompt: str,
        providers: Optional[list[ProviderStatus]] = None,
    ) -> list[StepResult]:
        """Run same prompt against multiple models (review/cross-check mode).

        Concurrency capped by config.max_parallel.
        """
        if providers is None:
            providers = check_providers(self.config)

        cap = max(1, self.config.max_parallel)
        results: list[StepResult] = []

        if cap == 1 or len(models) == 1:
            for m in models:
                results.append(self.run_step(m, prompt, providers))
            return results

        with ThreadPoolExecutor(max_workers=cap) as pool:
            futures = {pool.submit(self.run_step, m, prompt, providers): m for m in models}
            for fut in as_completed(futures):
                results.append(fut.result())

        return results

    def run_plan(self, steps: list[PlanStep]) -> list[StepResult]:
        """Execute an ordered plan sequentially. Stops on blocked/needs-info."""
        providers = check_providers(self.config)
        results: list[StepResult] = []

        for step in steps:
            result = self.run_step(step.model, step.prompt, providers)
            results.append(result)
            if result.footer.status in ("blocked", "needs-info"):
                break

        return results
