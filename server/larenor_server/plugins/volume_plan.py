"""Proposed managed appdata volumes, separate from native path plans."""


class VolumePlanError(ValueError):
    pass


def build_volume_plan(stack, catalog, policy):
    raise VolumePlanError('volume_plan_unavailable')


def verify_volume_plan(plan, stack, catalog, policy):
    raise VolumePlanError('volume_plan_unavailable')
