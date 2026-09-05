from datetime import datetime, timezone

import pytest
from pydantic import ValidationError

from larenor_server.plugins.preflight_models import PreflightCheck, PreflightResult


def result(**changes):
    return dict(catalogDigest='a' * 64, planHash='b' * 64, platform='linux/amd64',
                checkedAt='2026-09-05T12:00:00.000Z',
                checks=[dict(code='platform', status='passed')], **changes)


def test_preflight_model_has_explicit_unknowns_and_bounded_safe_values():
    data = PreflightResult.model_validate(result())
    assert data.checks[0].model_dump() == dict(code='platform', status='passed', rootId=None,
                                             availableMiB=None, requiredMiB=None)
    assert PreflightCheck(code='storage_capacity', status='failed', rootId='media',
                          availableMiB=0, requiredMiB=1024).availableMiB == 0


@pytest.mark.parametrize('field,value', [
    ('checkedAt', '2026-09-05'), ('checkedAt', '2026-09-05T12:00:00+03:00'),
    ('checkedAt', '2026-02-30T12:00:00.000Z'), ('platform', 'darwin/arm64'),
    ('catalogDigest', 'A' * 64), ('planHash', 'sha256:' + 'b' * 64),
    ('checks', []), ('checks', [dict(code='platform', status='passed')] * 33),
])
def test_invalid_preflight_result_is_rejected(field, value):
    raw = result(); raw[field] = value
    with pytest.raises(ValidationError):
        PreflightResult.model_validate(raw)


@pytest.mark.parametrize('changes', [
    dict(code='raw_host_error'), dict(status='ready'), dict(rootId='/private/secret'),
    dict(rootId='bad\nname'), dict(availableMiB=True), dict(requiredMiB=-1),
    dict(extra='raw-path'), dict(availableMiB=2**63),
])
def test_invalid_or_unbounded_check_is_rejected(changes):
    raw = dict(code='storage_root', status='unknown'); raw.update(changes)
    with pytest.raises(ValidationError):
        PreflightCheck.model_validate(raw)
