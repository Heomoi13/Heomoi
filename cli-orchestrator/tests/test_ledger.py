"""Tests for ledger read/write — no LLM calls."""
import os
import tempfile
from pathlib import Path

import pytest
from cli_orchestrator.ledger import append_entry, read_context


class TestReadContext:
    def test_missing_file_returns_empty(self, tmp_path):
        assert read_context(str(tmp_path)) == ""

    def test_reads_existing_file(self, tmp_path):
        (tmp_path / "AGENT_LOG.md").write_text("# Log\n## Entry", encoding="utf-8")
        ctx = read_context(str(tmp_path))
        assert "# Log" in ctx


class TestAppendEntry:
    def test_creates_file_if_missing(self, tmp_path):
        append_entry(str(tmp_path), "claude", "test step", "Reply here.")
        p = tmp_path / "AGENT_LOG.md"
        assert p.exists()
        content = p.read_text()
        assert "AGENT_LOG" in content
        assert "claude" in content
        assert "Reply here." in content

    def test_appends_to_existing_file(self, tmp_path):
        p = tmp_path / "AGENT_LOG.md"
        p.write_text("# AGENT_LOG\n", encoding="utf-8")
        append_entry(str(tmp_path), "gemini", "step 1", "First reply.")
        append_entry(str(tmp_path), "openai", "step 2", "Second reply.")
        content = p.read_text()
        assert "First reply." in content
        assert "Second reply." in content
        assert content.index("First reply.") < content.index("Second reply.")

    def test_entry_contains_timestamp(self, tmp_path):
        append_entry(str(tmp_path), "claude", "prompt", "reply")
        content = (tmp_path / "AGENT_LOG.md").read_text()
        # UTC timestamp pattern
        import re
        assert re.search(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC", content)

    def test_entry_contains_model(self, tmp_path):
        append_entry(str(tmp_path), "openai", "a prompt", "a reply")
        content = (tmp_path / "AGENT_LOG.md").read_text()
        assert "openai" in content

    def test_path_is_relative_to_workspace(self, tmp_path):
        # File is created at workspace root, not some absolute path
        append_entry(str(tmp_path), "claude", "p", "r")
        assert (tmp_path / "AGENT_LOG.md").exists()
        # No file should be created outside workspace
        assert not Path("/AGENT_LOG.md").exists()
