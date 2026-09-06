"""Fixed CI-only observations/owned sentinels; not shipped in the Server image.

No caller path, URL, credential or command is accepted. The separate helper
entrypoint performs bootstrap; these characterization commands run as 1000:1000
with no capabilities, and never initialize/chown application directories.
"""
import json
import os
import re
import stat
import sys
import urllib.error
import urllib.request


_ROOT = '/volume'
_WRITE_TEST = '.larenor-write-probe-v1'
_SENTINEL = '.larenor-storage-fixture-v1'
_IMAGE_SEED = '.larenor-image-seed-v1'
_CONTENT = b'larenor-owned-ci-storage-fixture-v1\n'
_MODES = {'writable','write_sentinel','verify_sentinel','initial_data','health','image_seed'}


class ProbeError(Exception):
    def __init__(self):
        super().__init__('fixture_probe_failed')


def _require(value):
    if not value:
        raise ProbeError()


def _open(fd, name, flags=os.O_RDONLY):
    return os.open(name, flags | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=fd)


def _read_file(fd, name, limit):
    item = _open(fd, name)
    try:
        info = os.fstat(item)
        _require(stat.S_ISREG(info.st_mode))
        return os.read(item, limit)
    finally:
        os.close(item)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ProbeError()


def _read(path):
    _require(path in {'/health','/System/Info/Public'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request('http://127.0.0.1:8096'+path,
        headers={'Accept':'application/json','Accept-Encoding':'identity'})
    with opener.open(request, timeout=2) as response:
        _require(response.status == 200)
        body = response.read(65537)
        _require(len(body) <= 65536)
        return body


def run(mode):
    _require(type(mode) is str and mode in _MODES)
    fd = None
    try:
        if mode == 'health':
            _require(_read('/health').strip() == b'Healthy')
            value = json.loads(_read('/System/Info/Public'))
            _require(type(value) is dict and type(value.get('Id')) is str
                and re.fullmatch(r'[0-9a-f]{32}', value['Id'])
                and value.get('Version') == '10.11.11'
                and value.get('StartupWizardCompleted') is False)
            return {'id':value['Id'],'version':value['Version'],'wizardCompleted':False}
        fd = os.open(_ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        identity = {'uid':os.geteuid(), 'gid':os.getegid()}
        if mode == 'image_seed':
            _require(_read_file(fd, _IMAGE_SEED, 128) == b'fixture-image-seed\n')
            return {'imageSeed':True}
        if mode == 'initial_data':
            for directory, filename, signature, maximum in (
                ('data','jellyfin.db',b'SQLite format 3\x00',16),
                ('config','system.xml',b'ServerConfiguration',4096)):
                child = _open(fd, directory, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    _require(signature in _read_file(child, filename, maximum))
                finally:
                    os.close(child)
            return {'database':True,'configuration':True}
        if mode in {'writable','write_sentinel'}:
            name = _WRITE_TEST if mode == 'writable' else _SENTINEL
            try:
                item = _open(fd, name, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
            except PermissionError:
                if mode != 'writable':
                    raise
                return {'writable':False, **identity}
            created = os.fstat(item)
            try:
                _require(os.write(item, _CONTENT) == len(_CONTENT))
                os.fsync(item)
            finally:
                os.close(item)
            if mode == 'writable':
                current = os.stat(name, dir_fd=fd, follow_symlinks=False)
                _require((created.st_dev, created.st_ino) == (current.st_dev, current.st_ino))
                os.unlink(name, dir_fd=fd)
                return {'writable':True, **identity}
        _require(_read_file(fd, _SENTINEL, len(_CONTENT)+1) == _CONTENT)
        return {'sentinel':'verified', **identity}
    except ProbeError:
        raise
    except (OSError, ValueError, TypeError, urllib.error.URLError):
        raise ProbeError() from None
    finally:
        if fd is not None:
            os.close(fd)


def main(arguments=None):
    args = sys.argv[1:] if arguments is None else arguments
    if len(args) != 1 or args[0] not in _MODES:
        print('fixture_probe_invalid', file=sys.stderr)
        return 2
    try:
        result = run(args[0])
    except ProbeError:
        print('fixture_probe_failed', file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
