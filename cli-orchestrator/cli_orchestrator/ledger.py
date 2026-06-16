from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path


def _ledger_path(workspace: str) -> Path:
    return Path(workspace) / "AGENT_LOG.md"


def read_context(workspace: str) -> str:
    """Return AGENT_LOG.md contents, or empty string if file doesn't exist."""
    p = _ledger_path(workspace)
    if p.exists():
        return p.read_text(encoding="utf-8")
    return ""


def append_entry(workspace: str, model: str, step_summary: str, reply_text: str) -> None:
    """Append a dated entry to AGENT_LOG.md, creating it if necessary."""
    p = _ledger_path(workspace)
    timestamp = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    entry = (
        f"\n---\n\n"
        f"## {timestamp} — {model}\n\n"
        f"**Step:** {step_summary}\n\n"
        f"**Reply:**\n\n{reply_text}\n"
    )

    if not p.exists():
        p.write_text(f"# AGENT_LOG\n{entry}", encoding="utf-8")
    else:
        with p.open("a", encoding="utf-8") as f:
            f.write(entry)
