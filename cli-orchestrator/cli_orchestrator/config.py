from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass
class Config:
    base_url: str = "http://127.0.0.1:8080"
    token: Optional[str] = None
    default_timeout: int = 120
    gemini_timeout: int = 300
    retries: int = 2
    max_parallel: int = 1
    # Loop safety guardrails
    max_steps: int = 12
    max_delegations: int = 20
    oscillation_limit: int = 2
    needs_info_limit: int = 2


def load_config(
    *,
    base_url: Optional[str] = None,
    token: Optional[str] = None,
    default_timeout: Optional[int] = None,
    gemini_timeout: Optional[int] = None,
    retries: Optional[int] = None,
    max_parallel: Optional[int] = None,
    max_steps: Optional[int] = None,
    max_delegations: Optional[int] = None,
    oscillation_limit: Optional[int] = None,
    needs_info_limit: Optional[int] = None,
    config_file: Optional[str] = None,
) -> Config:
    """Load config: CLI flags > env vars > config file > defaults."""
    cfg: dict = {}

    # Config file (lowest priority above defaults)
    if config_file:
        p = Path(config_file)
        if p.exists():
            cfg = json.loads(p.read_text())

    # Env vars
    _env_str(cfg, "CLI_CONTROLLER_URL", "base_url")
    _env_str(cfg, "CLI_CONTROLLER_TOKEN", "token")
    _env_int(cfg, "CLIO_DEFAULT_TIMEOUT", "default_timeout")
    _env_int(cfg, "CLIO_GEMINI_TIMEOUT", "gemini_timeout")
    _env_int(cfg, "CLIO_RETRIES", "retries")
    _env_int(cfg, "CLIO_MAX_PARALLEL", "max_parallel")
    _env_int(cfg, "CLIO_MAX_STEPS", "max_steps")
    _env_int(cfg, "CLIO_MAX_DELEGATIONS", "max_delegations")
    _env_int(cfg, "CLIO_OSCILLATION_LIMIT", "oscillation_limit")
    _env_int(cfg, "CLIO_NEEDS_INFO_LIMIT", "needs_info_limit")

    # CLI flags (highest priority)
    _flag(cfg, "base_url", base_url)
    _flag(cfg, "token", token)
    _flag(cfg, "default_timeout", default_timeout)
    _flag(cfg, "gemini_timeout", gemini_timeout)
    _flag(cfg, "retries", retries)
    _flag(cfg, "max_parallel", max_parallel)
    _flag(cfg, "max_steps", max_steps)
    _flag(cfg, "max_delegations", max_delegations)
    _flag(cfg, "oscillation_limit", oscillation_limit)
    _flag(cfg, "needs_info_limit", needs_info_limit)

    return Config(
        base_url=cfg.get("base_url", "http://127.0.0.1:8080"),
        token=cfg.get("token"),
        default_timeout=int(cfg.get("default_timeout", 120)),
        gemini_timeout=int(cfg.get("gemini_timeout", 300)),
        retries=int(cfg.get("retries", 2)),
        max_parallel=int(cfg.get("max_parallel", 1)),
        max_steps=int(cfg.get("max_steps", 12)),
        max_delegations=int(cfg.get("max_delegations", 20)),
        oscillation_limit=int(cfg.get("oscillation_limit", 2)),
        needs_info_limit=int(cfg.get("needs_info_limit", 2)),
    )


def _env_str(cfg: dict, env_key: str, cfg_key: str) -> None:
    v = os.environ.get(env_key)
    if v:
        cfg[cfg_key] = v


def _env_int(cfg: dict, env_key: str, cfg_key: str) -> None:
    v = os.environ.get(env_key)
    if v:
        cfg[cfg_key] = int(v)


def _flag(cfg: dict, key: str, value) -> None:
    if value is not None:
        cfg[key] = value
