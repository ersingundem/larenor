import importlib

import pytest

from test_home_resource_models import models, reference, scope


def facts(role='member'):
    m = models()
    actor = m.ActorFacts(userId='d' * 32, revision=2, role=role, disabled=False,
                         mustChangePassword=False, sessionCurrent=True)
    target = m.TargetFacts(ref=m.ResourceRef(**reference()), revision=3, aclRevision=4, active=True)
    grant = m.GrantSnapshot(subjectId=actor.userId, target=target.ref, aclRevision=4,
                            permissions=m.Permissions(read=True, write=False))
    return m, actor, target, grant


def evaluate(*args, **kwargs):
    return importlib.import_module('larenor_server.home_resources.authorization').evaluate_access(*args, **kwargs)


def test_member_explicit_read_does_not_authorize_write_or_other_user():
    m, actor, target, grant = facts()
    assert evaluate(m.HomeScope(**scope()), actor, target, grant, 'read').allowed
    assert not evaluate(m.HomeScope(**scope()), actor, target, grant, 'write').allowed
    assert not evaluate(m.HomeScope(**scope()), actor, target, None, 'read').allowed
    other = grant.model_copy(update={'subjectId': 'e' * 32})
    assert not evaluate(m.HomeScope(**scope()), actor, target, other, 'read').allowed


def test_current_admin_still_cannot_cross_home_or_core():
    m, actor, target, _ = facts('admin')
    assert evaluate(m.HomeScope(**scope()), actor, target, None, 'write').allowed
    for field in ('homeId', 'coreId'):
        changed = scope(); changed[field] = 'e' * 32
        assert not evaluate(m.HomeScope(**changed), actor, target, None, 'read').allowed


@pytest.mark.parametrize('field,value', [('disabled', True), ('mustChangePassword', True),
                                       ('sessionCurrent', False)])
def test_stale_or_unready_actor_never_passes_even_as_admin(field, value):
    m, actor, target, _ = facts('admin')
    actor = actor.model_copy(update={field: value})
    assert not evaluate(m.HomeScope(**scope()), actor, target, None, 'read').allowed


@pytest.mark.parametrize('changes', [dict(cancelled=True), dict(expected_user_revision=1),
    dict(expected_revision=2), dict(expected_acl_revision=3)])
def test_cancel_and_inflight_revision_changes_are_rejected(changes):
    m, actor, target, grant = facts()
    assert not evaluate(m.HomeScope(**scope()), actor, target, grant, 'read', **changes).allowed


def test_metadata_revision_change_does_not_revoke_current_grant():
    m, actor, target, grant = facts()
    renamed = target.model_copy(update={'revision': 4})
    assert evaluate(m.HomeScope(**scope()), actor, renamed, grant, 'read').allowed
    assert not evaluate(m.HomeScope(**scope()), actor, renamed, grant, 'read', expected_revision=3).allowed
    stale = grant.model_copy(update={'aclRevision': 3})
    assert not evaluate(m.HomeScope(**scope()), actor, renamed, stale, 'read').allowed


def test_inactive_target_or_wrong_target_grant_does_not_leak_access():
    m, actor, target, grant = facts()
    assert not evaluate(m.HomeScope(**scope()), actor, target.model_copy(update={'active': False}), grant, 'read').allowed
    other = grant.model_copy(update={'target': m.ResourceRef(**{**reference(), 'id': 'e' * 32})})
    assert not evaluate(m.HomeScope(**scope()), actor, target, other, 'read').allowed


@pytest.mark.parametrize('changes', [dict(cancelled=1), dict(expected_revision=True),
                                   dict(expected_acl_revision='4'), dict(expected_user_revision=0)])
def test_internal_noncanonical_inputs_are_not_accepted(changes):
    m, actor, target, grant = facts()
    with pytest.raises(ValueError):
        evaluate(m.HomeScope(**scope()), actor, target, grant, 'read', **changes)


def test_unknown_action_and_copy_tampering_are_rejected():
    m, actor, target, grant = facts()
    with pytest.raises(ValueError):
        evaluate(m.HomeScope(**scope()), actor, target, grant, 'credentials')
    with pytest.raises(ValueError):
        evaluate(m.HomeScope(**scope()), actor.model_copy(update={'role': 'superadmin'}), target, grant, 'read')
