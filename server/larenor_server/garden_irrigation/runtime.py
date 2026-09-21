"""Provider wiring for the safe irrigation recommendation surface."""

from .http import IrrigationHttpGateway
from .planner import IrrigationPlanner


def build_irrigation_gateway(provider, *, clock):
    planner = IrrigationPlanner(
        authorityResolver=provider.authority,
        policyResolver=provider.policy_by_id,
    )
    return IrrigationHttpGateway(
        planner=planner,
        provider=provider,
        clock_ms=lambda: int(clock() * 1000),
    )
