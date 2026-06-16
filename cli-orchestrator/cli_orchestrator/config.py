from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
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


def load_config(
    *,
    base_url: Optional[str] = None,
    token: Optional[str] = None,
    default_timeout: Optional[int] = None,
    gemini_timeout: Optional[int] = None,
    retries: Optional[int] = None,
    max_parallel: Optional[int] = None,
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
    if os.environ.get("CLI_CONTROLLER_URL"):
        cfg["base_url"] = os.environ["CLI_CONTROLLER_URL"]
    if os.environ.get("CLI_CONTROLLER_TOKEN"):
        cfg["token"] = os.environ["CLI_CONTROLLER_TOKEN"]
    if os.environ.get("CLIO_DEFAULT_TIMEOUT"):
        cfg["default_timeout"] = int(os.environ["CLIO_DEFAULT_TIMEOUT"])
    if os.environ.get("CLIO_GEMINI_TIMEOUT"):
        cfg["gemini_timeout"] = int(os.environ["CLIO_GEMINI_TIMEOUT"])
    if os.environ.get("CLIO_RETRIES"):
        cfg["retries"] = int(os.environ["CLIO_RETRIES"])
    if os.environ.get("CLIO_MAX_PARALLEL"):
        cfg["max_parallel"] = int(os.environ["CLIO_MAX_PARALLEL"])

    # CLI flags (highest priority)
    if base_url is not None:
        cfg["base_url"] = base_url
    if token is not None:
        cfg["token"] = token
    if default_timeout is not None:
        cfg["default_timeout"] = default_timeout
    if gemini_timeout is not None:
        cfg["gemini_timeout"] = gemini_timeout
    if retries is not None:
        cfg["retries"] = retries
    if max_parallel is not None:
        cfg["max_parallel"] = max_parallel

    return Config(
        base_url=cfg.get("base_url", "http://127.0.0.1:8080"),
        token=cfg.get("token"),
        default_timeout=int(cfg.get("default_timeout", 120)),
        gemini_timeout=int(cfg.get("gemini_timeout", 300)),
        retries=int(cfg.get("retries", 2)),
        max_parallel=int(cfg.get("max_parallel", 1)),
    )
