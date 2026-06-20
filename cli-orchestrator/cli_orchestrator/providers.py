from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from .config import Config
from .gateway import GatewayError, get_providers


@dataclass
class ProviderStatus:
    name: str
    available: bool
    supports_vision: bool
    error: Optional[str] = None


def check_providers(config: Config) -> list[ProviderStatus]:
    """Fetch provider list from gateway. Returns statuses; never raises."""
    try:
        raw = get_providers(config)
    except GatewayError as exc:
        return [ProviderStatus(name="gateway", available=False, supports_vision=False, error=str(exc))]
    except Exception as exc:
        return [ProviderStatus(name="gateway", available=False, supports_vision=False, error=f"Unexpected: {exc}")]

    result: list[ProviderStatus] = []
    for item in raw:
        result.append(
            ProviderStatus(
                name=item.get("name", "unknown"),
                available=bool(item.get("available", False)),
                supports_vision=bool(item.get("supports_vision", False)),
                error=item.get("error"),
            )
        )
    return result


def is_available(providers: list[ProviderStatus], model: str) -> bool:
    for p in providers:
        if p.name == model:
            return p.available
    return False
