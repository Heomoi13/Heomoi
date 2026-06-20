"""Tests for parse_footer — no LLM calls, pure deterministic parsing."""
import pytest
from cli_orchestrator.protocol import parse_footer, wrap_prompt


class TestParseFooterFull:
    def test_done(self):
        text = "Some reply.\n\nSTATUS: done\nFILES_CHANGED: src/foo.py, src/bar.py\nNEXT: Run tests"
        f = parse_footer(text)
        assert f.status == "done"
        assert "src/foo.py" in f.files_changed
        assert "src/bar.py" in f.files_changed
        assert f.next == "Run tests"

    def test_blocked(self):
        text = "STATUS: blocked\nFILES_CHANGED: none\nNEXT: Need clarification on scope"
        f = parse_footer(text)
        assert f.status == "blocked"
        assert f.files_changed == []
        assert "clarification" in f.next

    def test_needs_info(self):
        text = "STATUS: needs-info\nFILES_CHANGED: none\nNEXT: Please provide config"
        f = parse_footer(text)
        assert f.status == "needs-info"


class TestParseFooterCaseInsensitive:
    def test_uppercase(self):
        text = "STATUS: DONE\nFILES_CHANGED: NONE\nNEXT: continue"
        f = parse_footer(text)
        assert f.status == "done"

    def test_mixed_case_keys(self):
        text = "Status: Done\nFiles_Changed: none\nNext: Deploy"
        f = parse_footer(text)
        assert f.status == "done"
        assert f.next == "Deploy"


class TestParseFooterMissingLines:
    def test_missing_files(self):
        text = "STATUS: done\nNEXT: proceed"
        f = parse_footer(text)
        assert f.status == "done"
        assert f.files_changed == []

    def test_missing_next(self):
        text = "STATUS: done\nFILES_CHANGED: README.md"
        f = parse_footer(text)
        assert f.status == "done"
        assert f.next is None

    def test_missing_status(self):
        text = "FILES_CHANGED: a.py\nNEXT: done"
        f = parse_footer(text)
        assert f.status == "needs-info"

    def test_completely_empty(self):
        f = parse_footer("")
        assert f.status == "needs-info"
        assert f.files_changed == []
        assert f.next is None


class TestParseFooterGarbage:
    def test_garbage_around_footer(self):
        text = (
            "Here is my long reply with lots of text.\n\n"
            "I did many things.\n\n"
            "--- footer ---\n"
            "STATUS: done\n"
            "FILES_CHANGED: lib/utils.py\n"
            "NEXT: Write unit tests\n"
            "--- end ---"
        )
        f = parse_footer(text)
        assert f.status == "done"
        assert "lib/utils.py" in f.files_changed

    def test_unknown_status_degrades(self):
        text = "STATUS: completed\nFILES_CHANGED: none\nNEXT: nothing"
        f = parse_footer(text)
        assert f.status == "needs-info"

    def test_trailing_punctuation_on_status(self):
        text = "STATUS: done.\nFILES_CHANGED: none\nNEXT: ship it"
        f = parse_footer(text)
        assert f.status == "done"

    def test_multiple_files_newline_separated(self):
        text = "STATUS: done\nFILES_CHANGED: a.py\nb.py\nc.py\nNEXT: test"
        f = parse_footer(text)
        assert "a.py" in f.files_changed


class TestWrapPrompt:
    def test_non_openai_uses_system_role(self):
        msgs = wrap_prompt("Do the task", "", "claude")
        roles = [m["role"] for m in msgs]
        assert "system" in roles
        assert "user" in roles

    def test_openai_folds_system_into_user(self):
        msgs = wrap_prompt("Do the task", "", "openai")
        roles = [m["role"] for m in msgs]
        assert "system" not in roles
        assert roles == ["user"]
        assert "AGENT_LOG.md" in msgs[0]["content"]
        assert "Do the task" in msgs[0]["content"]

    def test_ledger_context_included(self):
        msgs = wrap_prompt("task", "## Prior context", "claude")
        system_content = next(m["content"] for m in msgs if m["role"] == "system")
        assert "Prior context" in system_content
