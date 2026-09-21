"""Production wiring for provider-backed power-budget recommendations."""

import hashlib
import hmac

from .http import PowerBudgetHttpGateway
from .service import PowerBudgetService


def build_power_budget_gateway(provider, *, database, master_key, clock):
    key = hmac.new(
        master_key,
        b"larenor:power-budget:v1:audit",
        hashlib.sha256,
    ).digest()
    service = PowerBudgetService(database, audit_key=key, worker=provider, clock=clock)
    service.validate_storage()
    return PowerBudgetHttpGateway(service=service, provider=provider)
