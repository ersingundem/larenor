"""Offline fixture boundary tests; never instantiate a real daemon."""
import importlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
from types import SimpleNamespace

import pytest


def api():
    name = 'tool.jellyfin_storage_smoke'
    assert importlib.util.find_spec(name) is not None, 'owned-daemon storage fixture is absent'
    return importlib.import_module(name)


@pytest.mark.parametrize('env,system,machine,uid', [
    ({}, 'Linux', 'x86_64', 0),
    ({'CI': 'true'}, 'Linux', 'x86_64', 0),
    ({'CI': 'true', 'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted', 'RUNNER_ARCH': 'X64', 'GITHUB_SHA': 'a'*40}, 'Linux', 'x86_64', 0),
    ({'CI': 'true', 'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_ARCH': 'X64', 'GITHUB_SHA': 'a'*40}, 'Darwin', 'arm64', 0),
    ({'CI': 'true', 'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_ARCH': 'X64', 'GITHUB_SHA': 'a'*40}, 'Linux', 'aarch64', 0),
    ({'CI': 'true', 'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_ARCH': 'X64', 'GITHUB_SHA': 'a'*40}, 'Linux', 'x86_64', 1000),
])
def test_native_ci_guard_before_process_or_files(env, system, machine, uid, monkeypatch):
    m = api()
    monkeypatch.setattr(m.tempfile, 'mkdtemp', lambda **_: pytest.fail('guard created directory'))
    monkeypatch.setattr(m.subprocess, 'Popen', lambda *a, **k: pytest.fail('guard created process'))
    with pytest.raises(m.SmokeError, match='^native_ephemeral_ci_required$'):
        m.native_platform(env, system, machine, uid)


@pytest.mark.parametrize('machine,arch,expected', [('x86_64','X64','linux/amd64'), ('aarch64','ARM64','linux/arm64')])
def test_native_architecture_is_not_qemu_or_caller_selected(machine, arch, expected):
    m = api()
    env = {'CI':'true','GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted',
           'RUNNER_ARCH':arch,'GITHUB_SHA':'a'*40}
    assert m.native_platform(env, 'Linux', machine, 0) == expected


@pytest.mark.parametrize('args', [[], ['--socket', '/var/run/docker.sock'], ['--run-ephemeral-ci', '--platform', 'linux/arm64']])
def test_cli_has_no_external_socket_or_platform_input(args, monkeypatch, capsys):
    m = api()
    monkeypatch.setattr(m, 'EphemeralDaemon', lambda: pytest.fail('invalid CLI starts daemon'))
    assert m.main(args) == 2
    assert capsys.readouterr().err == 'explicit_ephemeral_ci_flag_required\n'


@pytest.mark.parametrize('platform', ['linux/amd64','linux/arm64'])
def test_source_uses_real_pinned_plans_and_exact_jellyfin_resources(platform):
    m = api()
    source = m.fixture_source(platform)
    assert source.stack.installAvailable is False and source.volumes.installAvailable is False
    assert len(source.plan.resources) == 13 and len(source.volumes.resources) == 7
    assert source.image.serviceId == 'jellyfin'
    assert source.image.image.platform == platform
    assert source.image.image.reference.endswith('@'+source.image.image.digest)
    assert {v.target for v in source.targets} == {'/config','/cache'}
    assert all(v.containerUser == '1000:1000' and v.noCopy is True for v in source.targets)
    assert len({v.name for v in source.targets}) == 2


def test_preparation_consumes_actual_sqlite_image_volume_journals(tmp_path):
    m = api()
    from larenor_server.plugins.image_resources import ImageObservation
    from larenor_server.plugins.volume_effects import VolumeAbsent, VolumeCreateAcknowledgement, _inputs
    from larenor_server.plugins.volume_resources import VolumeObservation
    from larenor_server.plugins.resource_journal import _digest
    source = m.fixture_source('linux/amd64')
    events = []
    class Images:
        present = False
        def inspect(self, binding, *, cancelled=None):
            events.append('image_get')
            return ImageObservation(binding.config_digest, b'{}') if self.present else None
        def pull(self, binding, *, cancelled=None):
            events.append('image_pull')
            self.present = True
    class Volumes:
        present = set()
        def probe(self, intent, *, cancelled=None):
            rid = intent.binding.resource_id
            events.append(('volume_get', rid, intent.receipt.state))
            digest = _digest(_inputs(intent)[1])
            return (VolumeObservation(rid, intent.binding.resource.name, source.volumes.planHash, digest)
                if rid in self.present else VolumeAbsent(rid, digest))
        def create(self, intent, *, cancelled=None, before_dispatch=None):
            assert before_dispatch() is True
            events.append(('volume_post', intent.binding.resource_id, intent.receipt.state))
            self.present.add(intent.binding.resource_id)
            return VolumeCreateAcknowledgement(intent.binding.resource_id, _digest(_inputs(intent)[1]))
    images, volumes = Images(), Volumes()
    result = m.prepare_storage(tmp_path, source, images, volumes)
    assert result['imageState'] == 'ready'
    assert result['volumeStates'] == ['observed_requires_bootstrap']*2
    assert events[:4] == ['image_get','image_pull','image_get', ('volume_get',source.targets[0].resourceId,'mutating')]
    assert len([e for e in events if isinstance(e,tuple) and e[0]=='volume_post']) == 2
    before = list(events)
    assert m.prepare_storage(tmp_path, source, images, volumes) == result
    assert events == before, 'terminal receipts must not cause fresh CREATE/PULL'


def test_bounded_process_never_inherits_docker_or_proxy_configuration(monkeypatch, tmp_path):
    m = api()
    monkeypatch.setenv('DOCKER_HOST','unix:///var/run/docker.sock')
    monkeypatch.setenv('HTTP_PROXY','http://synthetic-private')
    output = m.bounded_command([sys.executable,'-c','import os,json; print(json.dumps(dict(os.environ)))'],
        environment=m.child_environment(tmp_path), timeout=3, limit=16384)
    env = json.loads(output)
    assert 'DOCKER_HOST' not in env and 'HTTP_PROXY' not in env
    assert env['DOCKER_CONFIG'] == str(tmp_path/'docker-config')


@pytest.mark.parametrize('program,limit,timeout', [
    ('import sys;sys.stdout.write("x"*10000)',32,3),
    ('import time;time.sleep(30)',32,0.05),
    ('import sys;print("synthetic-private");sys.exit(1)',128,3),
])
def test_command_limit_timeout_and_error_are_static_and_reaped(program, limit, timeout):
    m = api()
    with pytest.raises(m.SmokeError, match='^fixture_command_failed$'):
        m.bounded_command([sys.executable,'-c',program], environment={}, limit=limit, timeout=timeout)


def test_owned_daemon_command_disables_default_bridge_and_external_config(tmp_path):
    m = api()
    root = tmp_path/'owned'
    root.mkdir(mode=0o700)
    args = m.daemon_command(root)
    assert args[:2] == ['/usr/bin/unshare','--mount']
    assert '--pid' in args and '--fork' in args and '--kill-child=SIGKILL' in args
    assert '--host=unix://'+str(root/'engine.sock') in args
    assert '--data-root='+str(root/'data') in args
    assert '--exec-root='+str(root/'exec') in args
    assert '--config-file='+str(root/'daemon.json') in args
    assert '--bridge=none' in args and '--iptables=false' in args and '--ip-forward=false' in args
    assert not any('/var/run/' in arg or '/var/lib/docker' in arg for arg in args)


def test_helper_attestation_uses_actual_build_id_not_a_fabricated_manifest(tmp_path):
    m = api()
    inspected = {'Id':'sha256:'+'f'*64,'Os':'linux','Architecture':'amd64', 'RepoDigests':[]}
    value = m.helper_attestation('sha256:'+'f'*64, inspected, 'linux/amd64', 'a'*40)
    assert value['configDigest'] == inspected['Id'] and value['publishedManifestDigest'] is None
    assert value['sourceCommit'] == 'a'*40 and len(value['helperSourceSha256']) == 64
    with pytest.raises(m.SmokeError):
        m.helper_attestation('sha256:'+'e'*64, inspected, 'linux/amd64', 'a'*40)


def test_replaced_socket_fails_before_any_cli_dispatch(tmp_path):
    m = api()
    daemon = m.EphemeralDaemon()
    daemon.root = tmp_path
    daemon.process = SimpleNamespace(poll=lambda:None)
    daemon.socket_identity = (1,2)
    (tmp_path/'engine.sock').write_text('wrong object')
    with pytest.raises(m.SmokeError, match='^owned_daemon_lost$'):
        daemon.docker(['info'])
