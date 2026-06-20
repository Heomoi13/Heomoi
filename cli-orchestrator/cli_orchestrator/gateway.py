from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from typing import Optional

from .config import Config

_QUOTA_SIGNALS = (
    "quota",
    "rate limit",
    "usage limit",
    "credits",
    "insufficient_quota",
    "invalid api key",
    "invalid_api_key",
)


class GatewayError(Exception):
    """Raised when gateway returns a non-retriable error."""
    def __init__(self, message: str, status_code: Optional[int] = None):
        super().__init__(message)
        self.status_code = status_code


class GatewayTransientError(Exception):
    """Raised on retriable failures (5xx, empty reply, network)."""


def _is_quota_error(body: str) -> bool:
    lower = body.lower()
    return any(sig in lower for sig in _QUOTA_SIGNALS)


def _build_request(url: str, token: str, payload: dict) -> urllib.request.Request:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        method="POST",
    )
    return req


def chat_completion(
    *,
    config: Config,
    model: str,
    messages: list[dict],
    workspace: str,
    timeout: Optional[int] = None,
) -> str:
    """Send chat completion to gateway; return assistant text.

    Retries on 5xx / empty reply / network errors (linear backoff).
    Raises GatewayError immediately on 4xx or quota signals.
    """
    if not config.token:
        raise GatewayError("token not configured (set CLI_CONTROLLER_TOKEN)")

    cli_timeout = timeout if timeout is not None else config.default_timeout
    http_timeout = cli_timeout + 30  # headroom

    payload = {
        "model": model,
        "messages": messages,
        "timeout": cli_timeout,
        "cwd": workspace,
    }

    url = f"{config.base_url.rstrip('/')}/v1/chat/completions"
    last_exc: Exception = GatewayTransientError("No attempts made")

    for attempt in range(config.retries + 1):
        if attempt > 0:
            time.sleep(attempt * 2)  # linear backoff: 2s, 4s, 6s …

        try:
            req = _build_request(url, config.token, payload)
            with urllib.request.urlopen(req, timeout=http_timeout) as resp:
                body = resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
            if 400 <= exc.code < 500:
                raise GatewayError(
                    f"HTTP {exc.code}: {body[:200]}", status_code=exc.code
                )
            if _is_quota_error(body):
                raise GatewayError(
                    f"Quota/auth error from gateway: {body[:200]}", status_code=exc.code
                )
            last_exc = GatewayTransientError(f"HTTP {exc.code}")
            continue
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            last_exc = GatewayTransientError(str(exc))
            continue

        # Parse OpenAI-compatible response
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            last_exc = GatewayTransientError("Invalid JSON response")
            continue

        # Check for quota/auth signals in successful response body
        if _is_quota_error(body):
            raise GatewayError(f"Quota/auth signal in response: {body[:200]}")

        text = ""
        try:
            text = data["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, TypeError):
            pass

        if not text.strip():
            last_exc = GatewayTransientError("Empty reply from worker")
            continue

        return text

    raise last_exc


def get_providers(config: Config) -> list[dict]:
    """GET /api/providers; returns list of provider dicts or raises."""
    url = f"{config.base_url.rstrip('/')}/api/providers"
    req = urllib.request.Request(url, method="GET")
    if config.token:
        req.add_header("Authorization", f"Bearer {config.token}")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        raise GatewayError(f"HTTP {exc.code}", status_code=exc.code)
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        raise GatewayError(f"Cannot reach gateway: {exc}")
