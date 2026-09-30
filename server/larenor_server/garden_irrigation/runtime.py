"""Provider wiring for the safe irrigation recommendation surface."""

from .http import IrrigationHttpGateway
from .models import IrrigationAuthority
from .planner import IrrigationPlanner


def build_irrigation_gateway(provider, *, clock):
    def current_authority(expected):
        current = getattr(provider, "current_authority", None)
        if callable(current):
            return current(expected)
        value = IrrigationAuthority.model_validate(expected)
        return provider.authority(value.accountId)

    planner = IrrigationPlanner(
        authorityResolver=current_authority,
        policyResolver=provider.policy_by_id,
    )
    return IrrigationHttpGateway(
        planner=planner, authority_resolver=current_authority,
        provider=provider,
        clock_ms=lambda: int(clock() * 1000),
    )
