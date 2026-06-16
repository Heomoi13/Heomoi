"""Tests for the orchestrator observe-replan loop — all deterministic, no real LLM.

Uses MockPlanner (a stub that returns a predetermined sequence of decisions) and
patches chat_completion + check_providers/is_available so no network calls happen.
"""
from __future__ import annotations

from contextlib import contextmanager
from unittest.mock import patch

import pytest

from cli_orchestrator.config import Config
from cli_orchestrator.orchestrator import Orchestrator
from cli_orchestrator.planner import Done, Escalate, StaticPlanner, Step
from cli_orchestrator.providers import ProviderStatus


# ── Test helpers ──────────────────────────────────────────────────────────────

def _cfg(**kw) -> Config:
    defaults = dict(
        base_url="http://127.0.0.1:8080",
        token="test-token",
        default_timeout=10,
        gemini_timeout=30,
        retries=0,
        max_parallel=1,
        max_steps=12,
        max_delegations=20,
        oscillation_limit=2,
        needs_info_limit=2,
    )
    defaults.update(kw)
    return Config(**defaults)


class MockPlanner:
    """Stub planner returning a predetermined sequence of decisions."""

    def __init__(self, decisions: list) -> None:
        self._decisions = list(decisions)
        self._idx = 0
        self.calls: list[tuple] = []

    def next_step(self, ledger_context: str, history: list):
        self.calls.append((ledger_context, list(history)))
        if self._idx >= len(self._decisions):
            return Done("mock exhausted")
        d = self._decisions[self._idx]
        self._idx += 1
        return d


def _done_reply(text: str = "work done") -> str:
    return f"{text}\n\nSTATUS: done\nFILES_CHANGED: none\nNEXT: proceed"

def _needs_info_reply() -> str:
    return "STATUS: needs-info\nFILES_CHANGED: none\nNEXT: please clarify"


@contextmanager
def _mocked(available: tuple[str, ...] = ("claude",), gateway_reply: str | None = None):
    """Patch providers and gateway for a run."""
    if gateway_reply is None:
        gateway_reply = _done_reply()
    providers = [ProviderStatus(n, available=True, supports_vision=False) for n in available]
    with patch("cli_orchestrator.orchestrator.check_providers", return_value=providers):
        with patch("cli_orchestrator.orchestrator.is_available",
                   side_effect=lambda ps, m: m in available):
            with patch("cli_orchestrator.orchestrator.chat_completion",
                       return_value=gateway_reply):
                yield


# ── Tests: terminal decisions ─────────────────────────────────────────────────

class TestTerminalDecisions:
    def test_done_immediately(self, tmp_path):
        planner = MockPlanner([Done("finished right away")])
        orch = Orchestrator(str(tmp_path), _cfg())
        with _mocked():
            result = orch.run(planner)
        assert result.status == "done"
        assert result.summary == "finished right away"
        assert result.history == []

    def test_escalate_immediately(self, tmp_path):
        planner = MockPlanner([Escalate("need human input")])
        orch = Orchestrator(str(tmp_path), _cfg())
        with _mocked():
            result = orch.run(planner)
        assert result.status == "escalated"
        assert result.escalation_reason == "need human input"
        assert result.history == []

    def test_done_after_steps(self, tmp_path):
        planner = MockPlanner([
            Step("claude", "step A"),
            Step("claude", "step B"),
            Done("all steps done"),
        ])
        orch = Orchestrator(str(tmp_path), _cfg())
        with _mocked():
            result = orch.run(planner)
        assert result.status == "done"
        assert len(result.history) == 2


# ── Tests: StaticPlanner ──────────────────────────────────────────────────────

class TestStaticPlanner:
    def test_runs_steps_in_order(self, tmp_path):
        steps = [Step("claude", f"step {i}") for i in range(3)]
        planner = StaticPlanner(steps)
        orch = Orchestrator(str(tmp_path), _cfg())
        with _mocked():
            result = orch.run(planner)
        assert result.status == "done"
        assert len(result.history) == 3
        assert [r.model for r in result.history] == ["claude", "claude", "claude"]

    def test_done_after_last_step(self, tmp_path):
        planner = StaticPlanner([Step("claude", "only step")])
        orch = Orchestrator(str(tmp_path), _cfg())
        with _mocked():
            result = orch.run(planner)
        assert result.status == "done"
        assert "1 step" in result.summary

    def test_empty_plan_is_immediately_done(self, tmp_path):
        planner = StaticPlanner([])
        orch = Orchestrator(str(tmp_path), _cfg())
        with _mocked():
            result = orch.run(planner)
        assert result.status == "done"
        assert result.history == []


# ── Tests: safety guardrails ──────────────────────────────────────────────────

class TestMaxSteps:
    def test_cap_triggers_escalate(self, tmp_path):
        # Planner always returns a new step; cap at 2
        planner = MockPlanner([Step("claude", f"step {i}") for i in range(10)])
        orch = Orchestrator(str(tmp_path), _cfg(max_steps=2, oscillation_limit=99))
        with _mocked():
            result = orch.run(planner)
        assert result.status == "escalated"
        assert "max_steps" in result.escalation_reason
        assert len(result.history) == 2

    def test_exactly_at_cap(self, tmp_path):
        # max_steps=3 → 3 steps run, 4th is blocked
        planner = MockPlanner([Step("claude", f"step {i}") for i in range(5)])
        orch = Orchestrator(str(tmp_path), _cfg(max_steps=3, oscillation_limit=99))
        with _mocked():
            result = orch.run(planner)
        assert result.status == "escalated"
        assert len(result.history) == 3


class TestMaxDelegations:
    def test_cap_triggers_escalate(self, tmp_path):
        planner = MockPlanner([Step("claude", f"step {i}") for i in range(10)])
        orch = Orchestrator(str(tmp_path), _cfg(max_delegations=2, max_steps=99, oscillation_limit=99))
        with _mocked():
            result = orch.run(planner)
        assert result.status == "escalated"
        assert "max_delegations" in result.escalation_reason
        assert len(result.history) == 2


class TestOscillation:
    def test_same_step_twice_escalates(self, tmp_path):
        # oscillation_limit=2: same step appearing twice in a row → escalate
        planner = MockPlanner([
            Step("claude", "same prompt"),
            Step("claude", "same prompt"),
        ])
        orch = Orchestrator(str(tmp_path), _cfg(oscillation_limit=2, max_steps=99, max_delegations=99))
        with _mocked():
            result = orch.run(planner)
        assert result.status == "escalated"
        assert "oscillat" in result.escalation_reason
        # First step ran; second was blocked before execution
        assert len(result.history) == 1

    def test_different_prompts_no_oscillation(self, tmp_path):
        planner = MockPlanner([
            Step("claude", "step A"),
            Step("claude", "step B"),
            Done("done"),
        ])
        orch = Orchestrator(str(tmp_path), _cfg(oscillation_limit=2))
        with _mocked():
            result = orch.run(planner)
        assert result.status == "done"

    def test_same_step_after_break_resets(self, tmp_path):
        # A A B A A — the second "A A" sequence should still trigger
        planner = MockPlanner([
            Step("claude", "A"),
            Step("claude", "B"),  # breaks the streak
            Step("claude", "A"),
            Step("claude", "A"),  # new streak of 2 → escalate
        ])
        orch = Orchestrator(str(tmp_path), _cfg(oscillation_limit=2, max_steps=99, max_delegations=99))
        with _mocked():
            result = orch.run(planner)
        assert result.status == "escalated"
        assert "oscillat" in result.escalation_reason
        assert len(result.history) == 3  # A, B, A ran; second A blocked


class TestNeedsInfo:
    def test_repeated_needs_info_escalates(self, tmp_path):
        # needs_info_limit=2: two consecutive needs-info → escalate
        planner = MockPlanner([
            Step("claude", "step 1"),
            Step("claude", "step 2"),
        ])
        orch = Orchestrator(str(tmp_path), _cfg(needs_info_limit=2, oscillation_limit=99, max_steps=99))
        with _mocked(gateway_reply=_needs_info_reply()):
            result = orch.run(planner)
        assert result.status == "escalated"
        assert "needs-info" in result.escalation_reason
        assert len(result.history) == 2

    def test_needs_info_resets_on_done(self, tmp_path):
        call_count = [0]
        def _gateway(*args, **kwargs):
            call_count[0] += 1
            return _needs_info_reply() if call_count[0] == 1 else _done_reply()

        planner = MockPlanner([
            Step("claude", "step 1"),  # → needs-info (count=1)
            Step("claude", "step 2"),  # → done (resets count)
            Done("finished"),
        ])
        orch = Orchestrator(str(tmp_path), _cfg(needs_info_limit=2, oscillation_limit=99))
        providers = [ProviderStatus("claude", available=True, supports_vision=False)]
        with patch("cli_orchestrator.orchestrator.check_providers", return_value=providers):
            with patch("cli_orchestrator.orchestrator.is_available", return_value=True):
                with patch("cli_orchestrator.orchestrator.chat_completion", side_effect=_gateway):
                    result = orch.run(planner)
        assert result.status == "done"
        assert len(result.history) == 2


class TestProviderUnavailable:
    def test_escalates_without_switching(self, tmp_path):
        planner = MockPlanner([Step("gemini", "heavy task")])
        orch = Orchestrator(str(tmp_path), _cfg())
        # Only "claude" is available, not "gemini"
        with _mocked(available=("claude",)):
            result = orch.run(planner)
        assert result.status == "escalated"
        assert "gemini" in result.escalation_reason
        assert result.history == []  # no execution happened


# ── Tests: history and ledger ─────────────────────────────────────────────────

class TestHistory:
    def test_history_contains_all_results(self, tmp_path):
        planner = MockPlanner([
            Step("claude", "step 1"),
            Step("claude", "step 2"),
            Done("done"),
        ])
        orch = Orchestrator(str(tmp_path), _cfg())
        with _mocked():
            result = orch.run(planner)
        assert len(result.history) == 2
        for r in result.history:
            assert r.model == "claude"
            assert r.footer.status == "done"

    def test_ledger_file_created(self, tmp_path):
        planner = StaticPlanner([Step("claude", "write something")])
        orch = Orchestrator(str(tmp_path), _cfg())
        with _mocked():
            orch.run(planner)
        assert (tmp_path / "AGENT_LOG.md").exists()

    def test_planner_receives_ledger_context(self, tmp_path):
        planner = MockPlanner([
            Step("claude", "step 1"),
            Done("done"),
        ])
        orch = Orchestrator(str(tmp_path), _cfg())
        with _mocked():
            orch.run(planner)
        # Second call to next_step should have non-empty ledger context
        _, (ledger_after, _) = planner.calls[0], planner.calls[1]
        assert "AGENT_LOG" in ledger_after or len(ledger_after) > 0


# ── Tests: run_step (single step, no loop) ────────────────────────────────────

class TestRunStep:
    def test_returns_step_result(self, tmp_path):
        orch = Orchestrator(str(tmp_path), _cfg())
        with _mocked(gateway_reply=_done_reply("single step reply")):
            result = orch.run_step("claude", "do a thing")
        assert result.model == "claude"
        assert result.footer.status == "done"
        assert result.error is None

    def test_unavailable_provider_returns_error(self, tmp_path):
        orch = Orchestrator(str(tmp_path), _cfg())
        with _mocked(available=()):  # no providers available
            result = orch.run_step("claude", "do a thing")
        assert result.error is not None
        assert result.footer.status == "blocked"

    def test_creates_ledger_entry(self, tmp_path):
        orch = Orchestrator(str(tmp_path), _cfg())
        with _mocked():
            orch.run_step("claude", "a prompt")
        assert (tmp_path / "AGENT_LOG.md").exists()
