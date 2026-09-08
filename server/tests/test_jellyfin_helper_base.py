"""Synthetic exact-base runtime isolation before helper Dockerfile build."""
import json
from pathlib import Path

import pytest

from test_jellyfin_storage_diagnostics import launched, protocol


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
            assert '--network=none' in args and '--read-only' in args and '--cap-drop=ALL' in args
            assert '--user=0:0' in args and '--entrypoint=/usr/local/bin/python' in args
            assert not any(a.startswith(('--mount','--volume','--publish')) for a in args)
            state['args'] = args
        elif args[:2] == ['container','inspect'] and args[-1] == 'd'*64:
            phase = 'helper_base_result' if state['started'] else 'helper_base_created'
            result = json.dumps({'Id':'d'*64, 'Image':'sha256:'+'e'*64,
                'Config':{'User':'0:0','Entrypoint':['/usr/local/bin/python'],
                          'Cmd':['-I','-c','print("larenor-helper-base-ok-v1")']},
                'HostConfig':{'NetworkMode':'none','ReadonlyRootfs':True,'Privileged':False,
                    'CapDrop':['ALL'],'CapAdd':None,'Binds':None,'Mounts':None,'VolumesFrom':None},
                'Mounts':[], 'State':{'Status':'exited' if state['started'] else 'created',
                    'Running':False,'Paused':False,'Dead':False,'OOMKilled':False,'ExitCode':0}}).encode()
        elif args == ['start', '--attach', 'd'*64]:
            phase, result = 'helper_base_start', b'larenor-helper-base-ok-v1\n'
            state['started'] = True
        if phase is not None:
            events.append(phase)
            if state['fault'] == phase:
                raise ci.smoke.SmokeError('fixture_command_exit_failed')
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
    assert events[-1] == phase and events.count(phase) == 1
    assert 'helper_build' not in events and cleanup == ['enter','cleanup']
    output = capsys.readouterr()
    assert output.out == ''
    assert output.err == f'storage_characterization_failed phase={phase} code=fixture_command_exit_failed\n'
