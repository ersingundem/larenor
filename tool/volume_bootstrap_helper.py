"""Single-purpose container helper, not an installer or an ownership grant.

Only /volume, a distinct retained mount, can be inspected. Initial preparation
changes the empty root directory itself, never descendants. A failed metadata
write is not rolled back or retried. Caller must separately prove new-volume,
daemon/user mapping and dispatch authority; this executable supplies none.
"""
import json
import os
import re
import stat
import sys


_ROOT = '/volume'
_MODES = {'check', 'initialize_empty_root', 'verify_root'}


class BootstrapError(Exception):
    def __init__(self, code='bootstrap_unavailable'):
        self.code = code if code in {'bootstrap_invalid_command', 'bootstrap_conflict',
                                    'bootstrap_unavailable'} else 'bootstrap_unavailable'
        super().__init__(self.code)


def _require(value):
    if not value:
        raise BootstrapError('bootstrap_conflict')


def _mount_id(fd):
    with open(f'/proc/self/fdinfo/{fd}', 'rb') as source:
        raw = source.read(4097)
    _require(len(raw) <= 4096)
    found = re.findall(rb'^mnt_id:\s*([0-9]{1,20})$', raw, re.MULTILINE)
    _require(len(found) == 1)
    return int(found[0])


def _open_root():
    # Linux mnt_id distinguishes bind mounts even when st_dev is shared. Never
    # infer a mount from a directory name or os.path.ismount's device heuristic.
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    parent = os.open('/', flags)
    fd = None
    try:
        fd = os.open(_ROOT, flags)
        _require(_mount_id(fd) != _mount_id(parent))
        value = os.stat(_ROOT, follow_symlinks=False)
        held = os.fstat(fd)
        _require((value.st_dev, value.st_ino) == (held.st_dev, held.st_ino))
        result, fd = fd, None
        return result
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent)


def _empty(fd):
    # Stop at the first entry; do not accumulate filenames or traverse a tree.
    with os.scandir(fd) as entries:
        return next(entries, None) is None


def _metadata(value):
    _require(stat.S_ISDIR(value.st_mode))
    return value.st_uid, value.st_gid, stat.S_IMODE(value.st_mode)


def run(mode):
    if type(mode) is not str or mode not in _MODES:
        raise BootstrapError('bootstrap_invalid_command')
    fd = None
    try:
        fd = _open_root()
        before = os.fstat(fd)
        if mode == 'verify_root':
            _require(_metadata(before) == (1000, 1000, 0o750))
            result = 'root_verified'
        else:
            _require(_metadata(before) == (0, 0, 0o755) and _empty(fd))
            result = 'empty_uninitialized'
            if mode == 'initialize_empty_root':
                _require(os.geteuid() == 0)
                _require(_metadata(os.fstat(fd)) == (0, 0, 0o755) and _empty(fd))
                os.fchmod(fd, 0o750)
                os.fchown(fd, 1000, 1000)
                os.fsync(fd)
                _require(_metadata(os.fstat(fd)) == (1000, 1000, 0o750) and _empty(fd))
                result = 'empty_initialized'
        after = os.fstat(fd)
        _require((before.st_dev, before.st_ino) == (after.st_dev, after.st_ino))
        return {'schemaVersion': 1, 'state': result}
    except BootstrapError:
        raise
    except (OSError, ValueError, TypeError, OverflowError):
        raise BootstrapError() from None
    finally:
        if fd is not None:
            os.close(fd)


def main(arguments=None):
    args = sys.argv[1:] if arguments is None else arguments
    if len(args) != 1 or args[0] not in _MODES:
        print('bootstrap_invalid_command', file=sys.stderr)
        return 2
    try:
        result = run(args[0])
    except BootstrapError as error:
        print(error.code, file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
