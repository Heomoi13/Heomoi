#!/usr/bin/env python3
"""
dev_gateway.py — Minimal development gateway for cli-orchestrator.

A zero-dependency Python substitute for kjcli-controller. Wraps local AI CLIs
(claude, gemini/agy, openai/codex) behind an OpenAI-compatible HTTP API so that
`clio` works without the real binary.

NOT for production — single-threaded, no TLS, no streaming.

Quick start:
    export CLI_CONTROLLER_TOKEN=dev-token-change-me
    python3 scripts/dev_gateway.py            # default: 127.0.0.1:8080

    # Different port / host
    python3 scripts/dev_gateway.py --port 9090

    # In another terminal
    export CLI_CONTROLLER_TOKEN=dev-token-change-me
    clio providers
    clio step --model claude --workspace . --prompt "Hello"

Tuning CLI invocation (override per provider via env vars):
    CLIO_CLAUDE_CMD="claude -p {prompt}"      # {prompt} replaced at runtime
    CLIO_GEMINI_CMD="agy"                     # prompt piped via stdin
    CLIO_OPENAI_CMD="codex"                   # prompt piped via stdin
    CLIO_OPENAI_CMD="codex -q"                # quiet mode if supported

If a CLI reads from stdin, set command without {prompt} placeholder.
If a CLI takes a flag, include {prompt}: e.g. "claude -p {prompt}".
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from http import HTTPStatus
from typing import Optional
from urllib.parse import urlparse

# ── Configuration ─────────────────────────────────────────────────────────────

TOKEN: str = os.environ.get("CLI_CONTROLLER_TOKEN", "")

# Maps model name → local binary
PROVIDER_BINARIES: dict[str, str] = {
    "claude": "claude",
    "gemini": "agy",   # gateway looks for "agy"; symlink agy→gemini if needed
    "openai": "codex",
}

# CLI command templates per provider.
# Use {prompt} placeholder if the CLI takes the prompt as an argument.
# Omit {prompt} to pipe the prompt via stdin instead.
_DEFAULT_CMDS: dict[str, str] = {
    "claude": os.environ.get("CLIO_CLAUDE_CMD", "claude -p {prompt}"),
    "gemini": os.environ.get("CLIO_GEMINI_CMD", "agy"),
    "openai": os.environ.get("CLIO_OPENAI_CMD", "codex"),
}

# ── Message → prompt conversion ───────────────────────────────────────────────

def _messages_to_prompt(messages: list[dict]) -> str:
    """Flatten OpenAI messages list into a single prompt string."""
    parts: list[str] = []
    for msg in messages:
        role = msg.get("role", "user")
        content = msg.get("content", "")
        if role == "system":
            parts.append(f"[System]\n{content}")
        elif role == "user":
            parts.append(f"[User]\n{content}")
        elif role == "assistant":
            parts.append(f"[Assistant]\n{content}")
    return "\n\n".join(parts)


# ── CLI invocation ────────────────────────────────────────────────────────────

def _invoke_cli(model: str, prompt: str, cwd: str, timeout: int) -> str:
    """Run local CLI, return stdout. Raises RuntimeError on failure."""
    binary = PROVIDER_BINARIES.get(model)
    if not binary:
        raise RuntimeError(f"Unknown model: {model!r}")
    if not shutil.which(binary):
        raise RuntimeError(f"Binary not found in PATH: {binary!r}")

    cmd_template = _DEFAULT_CMDS.get(model, binary)
    use_stdin = "{prompt}" not in cmd_template

    if use_stdin:
        cmd = cmd_template.split()
        stdin_data = prompt.encode("utf-8")
    else:
        import shlex
        filled = cmd_template.replace("{prompt}", shlex.quote(prompt))
        cmd = shlex.split(filled)
        stdin_data = None

    try:
        result = subprocess.run(
            cmd,
            input=stdin_data,
            capture_output=True,
            timeout=timeout,
            cwd=cwd if os.path.isdir(cwd) else None,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"CLI timeout after {timeout}s")
    except FileNotFoundError:
        raise RuntimeError(f"Binary not found: {cmd[0]!r}")

    stdout = result.stdout.decode("utf-8", errors="replace").strip()
    stderr = result.stderr.decode("utf-8", errors="replace").strip()

    if result.returncode != 0:
        detail = stderr or stdout or f"exit code {result.returncode}"
        raise RuntimeError(f"CLI exited {result.returncode}: {detail[:300]}")

    if not stdout:
        raise RuntimeError("CLI produced empty output")

    return stdout


# ── HTTP handler ──────────────────────────────────────────────────────────────

class GatewayHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):  # noqa: N802
        ts = time.strftime("%H:%M:%S")
        print(f"[{ts}] {fmt % args}", file=sys.stderr)

    # ── Auth ──────────────────────────────────────────────────────────────────

    def _check_auth(self) -> bool:
        if not TOKEN:
            return True  # no token configured → open (dev convenience)
        auth = self.headers.get("Authorization", "")
        return auth == f"Bearer {TOKEN}"

    def _send_json(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self) -> Optional[dict]:
        length = int(self.headers.get("Content-Length", 0))
        if not length:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return None

    # ── GET /api/providers ────────────────────────────────────────────────────

    def do_GET(self):  # noqa: N802
        if not self._check_auth():
            self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
            return

        if urlparse(self.path).path == "/api/providers":
            providers = []
            for model, binary in PROVIDER_BINARIES.items():
                providers.append({
                    "name": model,
                    "available": shutil.which(binary) is not None,
                    "supports_vision": False,
                })
            self._send_json(HTTPStatus.OK, providers)
        else:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    # ── POST /v1/chat/completions ─────────────────────────────────────────────

    def do_POST(self):  # noqa: N802
        if not self._check_auth():
            self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
            return

        if urlparse(self.path).path != "/v1/chat/completions":
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return

        body = self._read_body()
        if body is None:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid JSON"})
            return

        model: str = body.get("model", "")
        messages: list = body.get("messages", [])
        cwd: str = body.get("cwd", os.getcwd())
        timeout: int = int(body.get("timeout", 120))

        if not model:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "model required"})
            return

        prompt = _messages_to_prompt(messages)

        try:
            text = _invoke_cli(model, prompt, cwd, timeout)
        except RuntimeError as exc:
            self._send_json(
                HTTPStatus.SERVICE_UNAVAILABLE,
                {"error": {"message": str(exc), "type": "gateway_error"}},
            )
            return

        response = {
            "id": f"chatcmpl-dev-{uuid.uuid4().hex[:8]}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }
        self._send_json(HTTPStatus.OK, response)


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="dev_gateway — minimal cli-orchestrator gateway"
    )
    parser.add_argument("--host", default="127.0.0.1", help="Bind host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8080, help="Bind port (default: 8080)")
    args = parser.parse_args()

    if not TOKEN:
        print(
            "WARNING: CLI_CONTROLLER_TOKEN is not set — gateway is open to anyone on localhost.",
            file=sys.stderr,
        )

    # Startup: show which CLIs are available
    print(f"dev_gateway starting on http://{args.host}:{args.port}", file=sys.stderr)
    for model, binary in PROVIDER_BINARIES.items():
        found = shutil.which(binary)
        mark = "✓" if found else "✗"
        print(f"  {mark} {model:8s} → {binary} {'(' + found + ')' if found else '(not found in PATH)'}", file=sys.stderr)
    print("", file=sys.stderr)

    server = http.server.HTTPServer((args.host, args.port), GatewayHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.", file=sys.stderr)
        server.shutdown()


if __name__ == "__main__":
    main()
