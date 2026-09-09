"""Rootful/remap-disabled daemon authority stays private and fail-closed."""

from dataclasses import dataclass
import json
import time

import pytest


def implementation():
    from larenor_server.plugins import daemon_security
    return daemon_security


def response(value, *, status=200, connection='keep-alive'):
    body = json.dumps(value, separators=(',', ':')).encode()
    return (f'HTTP/1.1 {status} test\r\nContent-Type: application/json\r\n'
            f'Content-Length: {len(body)}\r\nConnection: {connection}\r\n\r\n'.encode() + body)


VERSION = {
    'MinAPIVersion': '1.24',
    'ApiVersion': '1.47',
    'Os': 'linux',
    'Arch': 'amd64',
}


class Connection:
    def __init__(self, *, version=None, info=None):
        self.sent = []
        self.data = bytearray(
            response(VERSION if version is None else version)
            + response({'SecurityOptions': ['name=seccomp,profile=builtin', 'name=cgroupns']}
                       if info is None else info)
        )
        self.timeout = None

    def settimeout(self, value):
        self.timeout = value

    def sendall(self, value):
        self.sent.append(value)

    def recv(self, count):
        value = bytes(self.data[:count])
        del self.data[:count]
        return value


@dataclass(frozen=True)
class Snapshot:
    uids: tuple = (0, 0, 0, 0)
    gids: tuple = (0, 0, 0, 0)
    uid_map: tuple = ((0, 0, 4294967295),)
    gid_map: tuple = ((0, 0, 4294967295),)
    target_user_namespace: tuple = (1, 2)
    opener_user_namespace: tuple = (1, 2)


class Startup:
    def __init__(self, *, argv=None, config=b'{}'):
        self.argv = argv or ('/usr/bin/dockerd', '--config-file=/etc/docker/daemon.json')
        self.config = config
        self.checks = 0
        self.closed = False
        self.fail = False

    def check(self, _deadline):
        self.checks += 1
        if self.fail:
            raise RuntimeError('private-startup-change')

    def close(self):
        self.closed = True


def attest(*, connection=None, startup=None, peer=None, worker=None, platform='linux/amd64'):
    module = implementation()
    return module.attest_daemon_security(
        connection or Connection(),
        startup or Startup(),
        peer or Snapshot(),
        worker or Snapshot(),
        daemon_executable='/usr/bin/dockerd',
        platform=platform,
        deadline=time.monotonic() + 2,
    )


def test_valid_rootful_remap_disabled_daemon_retains_startup_evidence():
    connection, startup = Connection(), Startup()
    held = attest(connection=connection, startup=startup)
    assert len(connection.sent) == 2
    assert connection.sent[0].startswith(b'GET /version HTTP/1.1\r\n')
    assert connection.sent[1].startswith(b'GET /v1.47/info HTTP/1.1\r\n')
    assert all(b'Connection: keep-alive\r\n' in item for item in connection.sent)
    assert held.check(time.monotonic() + 2) is None
    held.close()
    assert startup.closed and startup.checks >= 2


@pytest.mark.parametrize('argv,config', [
    (('/usr/bin/dockerd', '--userns-remap=default'), b'{}'),
    (('/usr/bin/dockerd', '--userns-remap', 'default'), b'{}'),
    (('/usr/bin/dockerd', '--config-file', '/etc/docker/daemon.json'),
     b'{"userns-remap":"default"}'),
    (('/usr/bin/dockerd', '--config-file=/etc/docker/daemon.json'),
     b'{"userns-remap":"","userns-remap":"default"}'),
    (('/usr/bin/dockerd', '--config-file=/etc/one', '--config-file=/etc/two'), b'{}'),
    (('/usr/bin/dockerd', '--config-file'), b'{}'),
    (('/usr/bin/dockerd',), b'[]'),
    (('/usr/bin/other-daemon',), b'{}'),
])
def test_startup_arguments_and_config_reject_remap_or_ambiguity(argv, config):
    startup = Startup(argv=argv, config=config)
    with pytest.raises(implementation().DaemonSecurityError,
                       match='^daemon_security_unavailable$'):
        attest(startup=startup)
    assert startup.closed


@pytest.mark.parametrize('options', [
    ['name=rootless'], ['name=userns'], ['name=seccomp', 'name=userns,mode=default'],
    [], None, 'name=seccomp', [1], ['name=seccomp'] * 65,
])
def test_engine_security_options_must_explicitly_exclude_rootless_and_userns(options):
    with pytest.raises(implementation().DaemonSecurityError,
                       match='^daemon_security_unavailable$'):
        attest(connection=Connection(info={'SecurityOptions': options}))


@pytest.mark.parametrize('change', [
    {'peer': Snapshot(uids=(1000,) * 4)},
    {'worker': Snapshot(gids=(1000,) * 4)},
    {'peer': Snapshot(uid_map=((0, 100000, 65536),))},
    {'worker': Snapshot(gid_map=((0, 100000, 65536),))},
    {'peer': Snapshot(opener_user_namespace=(9, 9))},
    {'worker': Snapshot(target_user_namespace=(7, 8), opener_user_namespace=(7, 8))},
])
def test_initial_root_context_requires_full_identity_map_and_same_reader_namespace(change):
    with pytest.raises(implementation().DaemonSecurityError,
                       match='^daemon_security_unavailable$'):
        attest(**change)


@pytest.mark.parametrize('connection,platform,passes', [
    (Connection(version={**VERSION, 'ApiVersion': '1.46'}), 'linux/amd64', False),
    (Connection(), 'linux/arm64', False),
    (Connection(info={'SecurityOptions': ['name=seccomp']}), 'linux/amd64', True),
])
def test_version_platform_and_required_runtime_options_are_bounded(connection, platform, passes):
    if passes:
        held = attest(connection=connection, platform=platform)
        held.close()
        return
    with pytest.raises(implementation().DaemonSecurityError,
                       match='^daemon_security_unavailable$'):
        attest(connection=connection, platform=platform)


def test_changed_startup_evidence_invalidates_and_closes_the_lease():
    startup = Startup()
    held = attest(startup=startup)
    startup.fail = True
    with pytest.raises(implementation().DaemonSecurityError,
                       match='^daemon_security_unavailable$'):
        held.check(time.monotonic() + 2)
    assert startup.closed


def test_errors_and_repr_never_disclose_daemon_configuration():
    startup = Startup(config=b'{"private-secret":true}')
    held = attest(startup=startup)
    assert 'private-secret' not in repr(held)
    held.close()
    with pytest.raises(implementation().DaemonSecurityError) as caught:
        held.check(time.monotonic() + 2)
    assert caught.value.args == ('daemon_security_unavailable',)


@pytest.mark.parametrize('deadline', [True, None, float('nan'), float('inf'), -1, 0])
def test_invalid_deadline_fails_before_http_or_startup_access(deadline):
    module = implementation()
    connection, startup = Connection(), Startup()
    with pytest.raises(module.DaemonSecurityError,
                       match='^daemon_security_unavailable$'):
        module.attest_daemon_security(
            connection,
            startup,
            Snapshot(),
            Snapshot(),
            daemon_executable='/usr/bin/dockerd',
            platform='linux/amd64',
            deadline=deadline,
        )
    assert connection.sent == [] and startup.checks == 0
