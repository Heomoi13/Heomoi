"""Tests for gateway HTTP client — mock HTTP, no real network calls."""
from __future__ import annotations

import json
import urllib.error
import urllib.request
from io import BytesIO
from unittest.mock import MagicMock, patch

import pytest
from cli_orchestrator.config import Config
from cli_orchestrator.gateway import GatewayError, GatewayTransientError, chat_completion, get_providers


def _make_config(**kw) -> Config:
    defaults = dict(
        base_url="http://127.0.0.1:8080",
        token="test-token",
        default_timeout=10,
        gemini_timeout=30,
        retries=2,
        max_parallel=1,
    )
    defaults.update(kw)
    return Config(**defaults)


def _mock_response(body: str, status: int = 200):
    resp = MagicMock()
    resp.read.return_value = body.encode()
    resp.__enter__ = lambda s: s
    resp.__exit__ = MagicMock(return_value=False)
    return resp


def _ok_body(text: str = "Hello from worker") -> str:
    return json.dumps({
        "choices": [{"message": {"role": "assistant", "content": text}}]
    })


class TestChatCompletionSuccess:
    def test_returns_assistant_text(self):
        cfg = _make_config()
        with patch("urllib.request.urlopen", return_value=_mock_response(_ok_body("Done!"))):
            text = chat_completion(config=cfg, model="claude", messages=[{"role": "user", "content": "hi"}], workspace="/tmp")
        assert text == "Done!"

    def test_no_token_raises_gateway_error(self):
        cfg = _make_config(token=None)
        with pytest.raises(GatewayError, match="token"):
            chat_completion(config=cfg, model="claude", messages=[], workspace="/tmp")


class TestChatCompletionRetry:
    def test_retries_on_5xx(self):
        cfg = _make_config(retries=2)
        http_err = urllib.error.HTTPError(
            url="http://x", code=503, msg="Service Unavailable", hdrs=None, fp=BytesIO(b"error")
        )
        ok = _mock_response(_ok_body("ok after retry"))

        call_count = 0

        def fake_urlopen(req, timeout=None):
            nonlocal call_count
            call_count += 1
            if call_count < 3:
                raise http_err
            return ok

        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            with patch("time.sleep"):
                text = chat_completion(config=cfg, model="claude", messages=[], workspace="/tmp")
        assert text == "ok after retry"
        assert call_count == 3

    def test_retries_on_empty_reply(self):
        cfg = _make_config(retries=1)
        empty_body = json.dumps({"choices": [{"message": {"role": "assistant", "content": ""}}]})
        ok_body = _ok_body("eventually replied")

        call_count = 0

        def fake_urlopen(req, timeout=None):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                return _mock_response(empty_body)
            return _mock_response(ok_body)

        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            with patch("time.sleep"):
                text = chat_completion(config=cfg, model="claude", messages=[], workspace="/tmp")
        assert text == "eventually replied"

    def test_retries_on_network_error(self):
        cfg = _make_config(retries=1)
        import urllib.error

        call_count = 0

        def fake_urlopen(req, timeout=None):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise urllib.error.URLError("connection refused")
            return _mock_response(_ok_body("back online"))

        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            with patch("time.sleep"):
                text = chat_completion(config=cfg, model="claude", messages=[], workspace="/tmp")
        assert text == "back online"

    def test_exhausted_retries_raises_transient(self):
        cfg = _make_config(retries=1)
        http_err = urllib.error.HTTPError(url="http://x", code=500, msg="err", hdrs=None, fp=BytesIO(b"oops"))
        with patch("urllib.request.urlopen", side_effect=http_err):
            with patch("time.sleep"):
                with pytest.raises(GatewayTransientError):
                    chat_completion(config=cfg, model="claude", messages=[], workspace="/tmp")


class TestChatCompletionNoRetry:
    def test_no_retry_on_4xx(self):
        cfg = _make_config(retries=3)
        http_err = urllib.error.HTTPError(url="http://x", code=400, msg="Bad Request", hdrs=None, fp=BytesIO(b"bad"))

        call_count = 0

        def fake_urlopen(req, timeout=None):
            nonlocal call_count
            call_count += 1
            raise http_err

        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            with patch("time.sleep"):
                with pytest.raises(GatewayError) as exc_info:
                    chat_completion(config=cfg, model="claude", messages=[], workspace="/tmp")
        assert exc_info.value.status_code == 400
        assert call_count == 1  # no retry

    def test_no_retry_on_quota_in_5xx_body(self):
        cfg = _make_config(retries=3)
        quota_body = b'{"error": "insufficient_quota for this account"}'
        http_err = urllib.error.HTTPError(url="http://x", code=503, msg="err", hdrs=None, fp=BytesIO(quota_body))

        call_count = 0

        def fake_urlopen(req, timeout=None):
            nonlocal call_count
            call_count += 1
            raise http_err

        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            with patch("time.sleep"):
                with pytest.raises(GatewayError):
                    chat_completion(config=cfg, model="claude", messages=[], workspace="/tmp")
        assert call_count == 1  # no retry

    def test_no_retry_on_rate_limit_in_body(self):
        cfg = _make_config(retries=2)
        quota_body = b'{"error": "rate limit exceeded"}'
        http_err = urllib.error.HTTPError(url="http://x", code=503, msg="err", hdrs=None, fp=BytesIO(quota_body))

        call_count = 0

        def fake_urlopen(req, timeout=None):
            nonlocal call_count
            call_count += 1
            raise http_err

        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            with patch("time.sleep"):
                with pytest.raises(GatewayError):
                    chat_completion(config=cfg, model="claude", messages=[], workspace="/tmp")
        assert call_count == 1


class TestGetProviders:
    def test_returns_provider_list(self):
        cfg = _make_config()
        body = json.dumps([{"name": "claude", "available": True, "supports_vision": False}])
        with patch("urllib.request.urlopen", return_value=_mock_response(body)):
            result = get_providers(cfg)
        assert result[0]["name"] == "claude"
        assert result[0]["available"] is True

    def test_raises_gateway_error_on_http_error(self):
        cfg = _make_config()
        http_err = urllib.error.HTTPError(url="http://x", code=401, msg="Unauth", hdrs=None, fp=BytesIO(b""))
        with patch("urllib.request.urlopen", side_effect=http_err):
            with pytest.raises(GatewayError):
                get_providers(cfg)

    def test_raises_gateway_error_when_unreachable(self):
        cfg = _make_config()
        with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("refused")):
            with pytest.raises(GatewayError, match="Cannot reach gateway"):
                get_providers(cfg)


class TestTokenNotLogged:
    def test_token_not_in_error_message(self):
        cfg = _make_config(token="super-secret-xyz")
        http_err = urllib.error.HTTPError(url="http://x", code=500, msg="err", hdrs=None, fp=BytesIO(b"internal error"))
        with patch("urllib.request.urlopen", side_effect=http_err):
            with patch("time.sleep"):
                with pytest.raises(GatewayTransientError) as exc_info:
                    chat_completion(config=cfg, model="claude", messages=[], workspace="/tmp", )
        assert "super-secret-xyz" not in str(exc_info.value)
