"""Actual local Unix wire for the complete read-only media plan."""
import json
import time

import pytest

from larenor_server.plugins.preflight_ipc import PreflightIPCError
from larenor_server.plugins.preflight_models import PreflightCheck, PreflightResult
from test_media_host_preflight import stack
from test_plugin_preflight_ipc import running


class StackInspector:
    def __init__(self):
        self.calls = []

    def inspect_stack(self, selected, *, deadline):
        self.calls.append((selected, deadline))
        return PreflightResult(catalogDigest=selected.catalogDigest, planHash=selected.planHash,
            platform=selected.platform, checkedAt='2026-09-05T16:00:00.000Z', checks=[
                PreflightCheck(code='storage_capacity', status='failed', rootId='appdata',
                               availableMiB=16384, requiredMiB=49152),
                PreflightCheck(code='daemon_mount_context', status='unknown')])


def test_media_plan_roundtrip_uses_shared_deadline_and_exact_stack_identity():
    inspector = StackInspector()
    with running(inspector) as (_, client):
        selected = stack()
        begin = time.monotonic()
        result = client.inspect_stack(selected)
        assert result.planHash == selected.planHash
        assert result.checks[0].requiredMiB == 49152
        assert result.checks[1].status == 'unknown'
        assert len(inspector.calls) == 1
        assert inspector.calls[0][0] == selected
        assert begin < inspector.calls[0][1] <= begin + .4
        assert client.status()['installationAvailable'] is False


def test_untrusted_media_plan_never_reaches_inspector():
    inspector = StackInspector()
    with running(inspector) as (worker, client):
        changed = stack().model_copy(update={'planHash': 'f'*64})
        with pytest.raises(PreflightIPCError):
            client.inspect_stack(changed)
        request = {'protocol': 1, 'requestId': 'b'*32, 'operation': 'inspect_media',
                   'plan': changed.model_dump(mode='json')}
        with pytest.raises(PreflightIPCError):
            worker._answer(request, deadline=time.monotonic()+.2)
        assert inspector.calls == []


def test_expired_packet_budget_does_not_restart_at_host_inspection():
    inspector = StackInspector()
    with running(inspector) as (worker, _):
        request = {'protocol': 1, 'requestId': 'b'*32, 'operation': 'inspect_media',
                   'plan': stack().model_dump(mode='json')}
        with pytest.raises(PreflightIPCError):
            worker._answer(request, deadline=time.monotonic()-1)
        assert inspector.calls == []


@pytest.mark.parametrize('field,value', [('planHash', 'f'*64), ('catalogDigest', 'f'*64), ('platform', 'linux/arm64')])
def test_foreign_or_malformed_result_is_not_accepted(field, value):
    class Wrong(StackInspector):
        def inspect_stack(self, selected, *, deadline):
            return super().inspect_stack(selected, deadline=deadline).model_copy(update={field: value})
    with running(Wrong()) as (_, client):
        with pytest.raises(PreflightIPCError):
            client.inspect_stack(stack())
