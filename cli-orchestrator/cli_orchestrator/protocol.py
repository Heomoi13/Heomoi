from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class Footer:
    status: str  # "done" | "blocked" | "needs-info" | "unknown"
    files_changed: list[str]
    next: Optional[str]


_VALID_STATUSES = {"done", "blocked", "needs-info"}

_STATUS_RE = re.compile(r"STATUS\s*:\s*(\S+)", re.IGNORECASE)
_FILES_RE = re.compile(r"FILES_CHANGED\s*:\s*(.+)", re.IGNORECASE)
_NEXT_RE = re.compile(r"NEXT\s*:\s*(.+)", re.IGNORECASE)


def parse_footer(text: str) -> Footer:
    """Parse worker reply footer. Degrades safely on partial/malformed input."""
    status = "needs-info"
    files_changed: list[str] = []
    next_step: Optional[str] = None

    m = _STATUS_RE.search(text)
    if m:
        raw = m.group(1).strip().lower().rstrip(".,;")
        if raw in _VALID_STATUSES:
            status = raw

    m = _FILES_RE.search(text)
    if m:
        raw = m.group(1).strip()
        if raw.lower() not in ("none", ""):
            files_changed = [f.strip() for f in re.split(r"[,\n]+", raw) if f.strip()]

    m = _NEXT_RE.search(text)
    if m:
        next_step = m.group(1).strip() or None

    return Footer(status=status, files_changed=files_changed, next=next_step)


_LEDGER_INSTRUCTION = """\
Before starting your task, read the file AGENT_LOG.md in the workspace root \
(it may not exist yet — that is fine, skip silently). It contains context \
from previous steps.

After completing the task, append a dated entry to AGENT_LOG.md with:
- What you did
- Key decisions made
- Files changed (relative paths only)

End your entire reply with the following footer (no extra text after it):

STATUS: done | blocked | needs-info
FILES_CHANGED: <comma-separated relative paths, or none>
NEXT: <suggested next step>
"""


def wrap_prompt(prompt: str, ledger_context: str, model: str) -> list[dict]:
    """Build messages list for gateway, folding system into user for openai."""
    system_text = _LEDGER_INSTRUCTION
    if ledger_context:
        system_text = (
            f"Current AGENT_LOG.md context:\n\n{ledger_context}\n\n{_LEDGER_INSTRUCTION}"
        )

    user_text = prompt

    if model.lower().startswith("openai"):
        # Codex does not accept system role — fold into user message
        combined = f"{system_text}\n\n---\n\n{user_text}"
        return [{"role": "user", "content": combined}]

    return [
        {"role": "system", "content": system_text},
        {"role": "user", "content": user_text},
    ]
