"""Synthetic exact-base runtime isolation before helper Dockerfile build."""
import json
from pathlib import Path

import pytest

from test_jellyfin_storage_diagnostics import launched, protocol
from test_jellyfin_storage_smoke import copied_checkout


@pytest.fixture
def base_flow(launched, monkeypatch):
    ci, daemon, cleanup = launched
    original = daemon.docker
    reference = next(line.split()[1] for line in
        (Path(ci.smoke.REPOSITORY)/'server/Dockerfile.volume-bootstrap').read_text().splitlines()
        if line.startswith('FROM '))
    events = []
    state = {'fault':None, 'started':False}
    def docker(args, **kwargs):
        phase = None
        if args[0] == 'pull':
            assert args == ['pull', '--quiet', '--platform='+daemon.platform, reference]
            phase, result = 'helper_base_pull', (reference+'\n').encode()
        elif args[:2] == ['image','inspect'] and args[-1] == reference:
            phase = 'helper_base_inspect'
            result = json.dumps({'Id':'sha256:'+'e'*64, 'Os':'linux', 'Architecture':daemon.platform.split('/')[1],
                'RepoDigests':['python@'+reference.split('@')[1]], 'Config':{'Volumes':None}}).encode()
        elif args[0] == 'create' and '--name=larenor-helper-base-probe' in args:
            phase, result = 'helper_base_create', ('d'*64+'\n').encode()
            assert '--pull=never' in args
            assert '--network=none' in args and '--read-only' in args and '--cap-drop=ALL' in args
            assert '--user=0:0' in args and '--entrypoint=/usr/local/bin/python' in args
            assert '--cgroup-parent='+daemon.container_cgroup_parent in args
            assert not any(a.startswith(('--mount','--volume','--publish')) for a in args)
            state['args'] = args
        elif args[:2] == ['container','inspect'] and args[-1] == 'd'*64:
            phase = ('helper_base_start_state'
                if state['fault'] == 'helper_base_start' and events[-1:] == ['helper_base_start']
                else 'helper_base_result' if state['started'] else 'helper_base_created')
            value = {'Id':'d'*64, 'Image':'sha256:'+'e'*64,
                'Config':{'User':'0:0','Entrypoint':['/usr/local/bin/python'],
                          'Cmd':['-I','-c','print("larenor-helper-base-ok-v1")']},
                'HostConfig':{'NetworkMode':'none','ReadonlyRootfs':True,'Privileged':False,
                    'CapDrop':['ALL'],'CapAdd':None,'Binds':None,'Mounts':None,'VolumesFrom':None,
                    'CgroupParent':daemon.container_cgroup_parent},
                'Mounts':[], 'State':{'Status':'exited' if state['started'] else 'created',
                    'Running':False,'Paused':False,'Restarting':False,'Dead':False,
                    'OOMKilled':False,'ExitCode':0,'Error':''}}
            if args[3] == '{{json .State}}':
                value['State'].update(state.get('diagnostic_state', {}))
                result = json.dumps(value['State']).encode()
            else:
                result = json.dumps(value).encode()
        elif args == ['start', '--attach', 'd'*64]:
            phase, result = 'helper_base_start', b'larenor-helper-base-ok-v1\n'
            state['started'] = True
        if phase is not None:
            events.append(phase)
            if state['fault'] == phase:
                raise ci.smoke.SmokeError('fixture_command_exit_failed')
            if state.get('mutate') is not None:
                result = state['mutate'](phase, result)
            return result
        if args[0] == 'build':
            events.append('helper_build')
        return original(args, **kwargs)
    monkeypatch.setattr(daemon, 'docker', docker)
    return ci, daemon, cleanup, events, state


def test_actual_consumer_checks_exact_base_process_before_build(base_flow, capsys):
    ci, _, cleanup, events, _ = base_flow
    assert ci.main(['--run-ephemeral-ci']) == 0
    assert events == ['helper_base_pull','helper_base_inspect','helper_base_create',
                      'helper_base_created','helper_base_start','helper_base_result','helper_build']
    assert cleanup == ['enter','cleanup']
    value = json.loads(capsys.readouterr().out)
    assert value['result'] == 'characterized' and value['installAvailable'] is False


@pytest.mark.parametrize('phase', ['helper_base_pull','helper_base_inspect','helper_base_create',
                                  'helper_base_created','helper_base_start','helper_base_result'])
def test_failed_base_stage_never_builds_replays_or_skips_cleanup(base_flow, capsys, phase):
    ci, _, cleanup, events, state = base_flow
    state['fault'] = phase
    assert ci.main(['--run-ephemeral-ci']) == 1
    assert events[-1] == ('helper_base_start_state' if phase == 'helper_base_start' else phase)
    assert events.count(phase) == 1
    assert events.count('helper_base_start_state') == (1 if phase == 'helper_base_start' else 0)
    assert 'helper_build' not in events and cleanup == ['enter','cleanup']
    output = capsys.readouterr()
    assert output.out == ''
    code = 'helper_base_process_exited_zero' if phase == 'helper_base_start' else 'fixture_command_exit_failed'
    assert output.err == f'storage_characterization_failed phase={phase} code={code}\n'


def test_failed_start_uses_one_closed_state_reduction_before_cleanup(base_flow, capsys):
    ci, _, cleanup, events, state = base_flow
    state['fault'] = 'helper_base_start'
    state['diagnostic_state'] = {'Status':'exited','ExitCode':17}

    assert ci.main(['--run-ephemeral-ci']) == 1
    assert events == ['helper_base_pull','helper_base_inspect','helper_base_create',
        'helper_base_created','helper_base_start','helper_base_start_state']
    assert cleanup == ['enter','cleanup'] and 'helper_build' not in events
    assert capsys.readouterr().err == ('storage_characterization_failed '
        'phase=helper_base_start code=helper_base_process_nonzero\n')


@pytest.mark.parametrize('phase,path,replacement', [
    ('helper_base_inspect', ['Id'], 'sha256:bad'),
    ('helper_base_inspect', ['Os'], 'windows'),
    ('helper_base_inspect', ['Architecture'], 'arm64'),
    ('helper_base_inspect', ['RepoDigests'], ['python@sha256:'+'a'*64]),
    ('helper_base_inspect', ['Config','Volumes'], {'/foreign':{}}),
    ('helper_base_inspect', ['Config'], []),
    ('helper_base_created', ['Id'], 'a'*64),
    ('helper_base_created', ['Image'], 'sha256:'+'a'*64),
    ('helper_base_created', ['Config','User'], '1000:1000'),
    ('helper_base_created', ['Config','Cmd'], ['-c','other']),
    ('helper_base_created', ['Mounts'], [{'Destination':'/foreign'}]),
    ('helper_base_created', ['HostConfig','NetworkMode'], 'host'),
    ('helper_base_created', ['HostConfig','Privileged'], True),
    ('helper_base_created', ['HostConfig','Binds'], ['/foreign:/volume']),
    ('helper_base_created', ['State','Running'], True),
    ('helper_base_result', ['Image'], 'sha256:'+'a'*64),
    ('helper_base_result', ['State','Status'], 'running'),
    ('helper_base_result', ['State','ExitCode'], True),
    ('helper_base_result', ['State','ExitCode'], 1),
    ('helper_base_result', ['State','OOMKilled'], True),
])
def test_bound_probe_readback_fails_closed_without_build(base_flow, capsys, phase, path, replacement):
    ci, _, cleanup, events, state = base_flow
    def mutate(stage, raw):
        if stage != phase:
            return raw
        value = json.loads(raw)
        target = value
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = replacement
        return json.dumps(value).encode()
    state['mutate'] = mutate
    assert ci.main(['--run-ephemeral-ci']) == 1
    assert events[-1] == phase and 'helper_build' not in events
    assert cleanup == ['enter','cleanup']
    output = capsys.readouterr()
    assert output.out == ''
    assert output.err == f'storage_characterization_failed phase={phase} code=fixture_protocol_failed\n'


@pytest.mark.parametrize('phase,result', [
    ('helper_base_inspect', b'not-json-secret'),
    ('helper_base_create', b'not-a-container-id-secret'),
    ('helper_base_start', b'larenor-helper-base-ok-v1\nextra-secret'),
])
def test_invalid_protocol_or_stdout_never_escapes(base_flow, capsys, phase, result):
    ci, _, cleanup, events, state = base_flow
    state['mutate'] = lambda stage, raw: result if stage == phase else raw
    assert ci.main(['--run-ephemeral-ci']) == 1
    assert events[-1] == phase and 'helper_build' not in events
    output = capsys.readouterr()
    assert output.out == '' and 'secret' not in output.err
    assert output.err == f'storage_characterization_failed phase={phase} code=fixture_protocol_failed\n'
    assert cleanup == ['enter','cleanup']


@pytest.mark.parametrize('phase', ['helper_base_pull','helper_base_start'])
def test_base_command_cancellation_does_not_retry(base_flow, capsys, phase):
    ci, _, cleanup, events, state = base_flow
    def cancelled(stage, raw):
        if stage == phase:
            raise KeyboardInterrupt('synthetic-secret')
        return raw
    state['mutate'] = cancelled
    with pytest.raises(KeyboardInterrupt):
        ci.main(['--run-ephemeral-ci'])
    assert events[-1] == phase and events.count(phase) == 1
    assert 'helper_build' not in events and cleanup == ['enter','cleanup']
    assert capsys.readouterr().out == ''


@pytest.mark.parametrize('location', ['staged','checkout'])
def test_drift_during_base_probe_never_reaches_build(copied_checkout, location):
    smoke, source, daemon, images = copied_checkout
    original = daemon.docker
    def docker(args, **kwargs):
        result = original(args, **kwargs)
        if args == ['start','--attach','d'*64]:
            root = smoke.REPOSITORY if location == 'checkout' else daemon.root/'helper-context'
            (root/'LICENSE').write_text('drift during exact base probe')
        return result
    daemon.docker = docker
    with pytest.raises(smoke.SmokeError, match='^fixture_source_changed$') as caught:
        smoke.characterize(daemon, source=source, images=images, volumes=object())
    assert caught.value.phase == 'helper_base_result'
    assert not any(call[0] == 'build' for call in daemon.calls)


@pytest.mark.parametrize('replacement', [
    'FROM python:latest',
    'ARG BASE=python:latest\nFROM $BASE',
    'FROM python:3.12.14-slim-bookworm@sha256:'+'a'*64+'\nFROM other',
])
def test_unsupported_committed_from_shape_never_pulls(copied_checkout, replacement):
    smoke, source, daemon, images = copied_checkout
    path = smoke.REPOSITORY/'server/Dockerfile.volume-bootstrap'
    # Model a newly committed source with a format this fixed fixture does not support.
    path.write_text(replacement+'\n')
    with pytest.raises(smoke.SmokeError, match='^fixture_source_changed$') as caught:
        smoke.characterize(daemon, source=source, images=images, volumes=object())
    assert caught.value.phase == 'helper_base_binding'
    assert daemon.calls == []


def test_native_arm64_reference_is_pulled_once_and_config_id_is_only_create_input(protocol):
    smoke, _, daemon, _ = protocol
    daemon.platform = 'linux/arm64'
    binding = smoke.capture_source('a'*40)
    context = smoke.stage_context(daemon.root, binding)
    smoke._helper_base(daemon, context, binding)
    assert daemon.calls[0][2] == '--platform=linux/arm64'
    create = next(c for c in daemon.calls if c[0] == 'create')
    assert '--pull=never' in create and 'sha256:'+'e'*64 in create
    assert not any('python:' in arg for arg in create)
    assert sum(c[0] == 'pull' for c in daemon.calls) == 1
    assert sum(c[0] == 'create' for c in daemon.calls) == 1
    assert sum(c[0] == 'start' for c in daemon.calls) == 1
