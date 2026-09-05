"""Pure decisions over current facts. Decisions are never reusable execution grants."""
from .models import AccessDecision, ActorFacts, GrantSnapshot, HomeScope, TargetFacts


def evaluate_access(scope: HomeScope, actor: ActorFacts, target: TargetFacts,
                    grant: GrantSnapshot | None, action: str, *,
                    expected_user_revision: int | None = None,
                    expected_revision: int | None = None,
                    expected_acl_revision: int | None = None,
                    cancelled: bool = False) -> AccessDecision:
    scope = HomeScope.model_validate(scope)
    actor = ActorFacts.model_validate(actor)
    target = TargetFacts.model_validate(target)
    if grant is not None:
        grant = GrantSnapshot.model_validate(grant)
    if action not in ('read', 'write') or type(cancelled) is not bool:
        raise ValueError('invalid_access_request')
    for value in (expected_user_revision, expected_revision, expected_acl_revision):
        if value is not None and (type(value) is not int or not 1 <= value <= 2**63 - 1):
            raise ValueError('invalid_revision')

    def decision(code):
        return AccessDecision(allowed=code == 'allowed', code=code)

    if (scope.coreId, scope.homeId) != (target.ref.coreId, target.ref.homeId):
        return decision('scope_mismatch')
    if cancelled:
        return decision('cancelled')
    if actor.disabled or actor.mustChangePassword or not actor.sessionCurrent:
        return decision('actor_invalid')
    if not target.active:
        return decision('target_unavailable')
    if any(expected is not None and expected != actual for expected, actual in (
            (expected_user_revision, actor.revision), (expected_revision, target.revision),
            (expected_acl_revision, target.aclRevision))):
        return decision('revision_conflict')
    if actor.role == 'admin':
        return decision('allowed')
    if (grant is None or grant.subjectId != actor.userId or grant.target != target.ref or
            grant.aclRevision != target.aclRevision):
        return decision('forbidden')
    return decision('allowed' if getattr(grant.permissions, action) else 'forbidden')
