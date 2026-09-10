"""Single-purpose container helper, not an installer or an ownership grant.

Only /volume, a distinct retained mount, can be inspected. Initial preparation
changes the empty root directory itself. Separate modes create the fixed media
directories or install a validated qBittorrent configuration at one fixed
private path. Configuration bytes are accepted only through stdin and are never
returned. A failed write is not rolled back or retried. Caller must separately
prove new-volume, daemon/user mapping and dispatch authority; this executable
supplies none.
"""
import base64
import binascii
import errno
import hashlib
import hmac
import json
import os
import re
import stat
import sys


_ROOT = '/volume'
_MODES = {
    'check', 'initialize_empty_root', 'verify_root',
    'prepare_media_directories', 'install_qbittorrent_config',
}
_MEDIA_DIRECTORIES = ('movies', 'shows')
_QBITTORRENT_DIRECTORY = 'qBittorrent'
_QBITTORRENT_CONFIG = 'qBittorrent.conf'
_QBITTORRENT_TEMP = '.larenor-qbittorrent-config.tmp'
_QBITTORRENT_PATTERN = re.compile(
    rb'\[BitTorrent\]\n'
    rb'Session\\DefaultSavePath=/data/downloads\n'
    rb'Session\\Port=([0-9]{4,5})\n'
    rb'Session\\TempPath=/data/incomplete\n'
    rb'Session\\TempPathEnabled=true\n\n'
    rb'\[Network\]\n'
    rb'PortForwardingEnabled=false\n\n'
    rb'\[Preferences\]\n'
    rb'WebUI\\APIKey=(qbt_[A-Za-z0-9_-]{28})\n'
    rb'WebUI\\Address=\*\n'
    rb'WebUI\\AuthSubnetWhitelistEnabled=false\n'
    rb'WebUI\\ClickjackingProtection=true\n'
    rb'WebUI\\CSRFProtection=true\n'
    rb'WebUI\\HostHeaderValidation=true\n'
    rb'WebUI\\LocalHostAuth=true\n'
    rb'WebUI\\Password_PBKDF2="@ByteArray\('
    rb'([A-Za-z0-9+/]{22}==):([A-Za-z0-9+/]{86}==)\)"\n'
    rb'WebUI\\Port=([0-9]{4,5})\n'
    rb'WebUI\\SecureCookie=true\n'
    rb'WebUI\\ServerDomains=qbittorrent\n'
    rb'WebUI\\UseUPnP=false\n'
    rb'WebUI\\Username=larenor-system\n\Z')


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


def _prepare_media_directories(fd):
    _require(_metadata(os.fstat(fd)) == (1000, 1000, 0o750))
    _require(os.geteuid() == 1000 and os.getegid() == 1000)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    for name in _MEDIA_DIRECTORIES:
        try:
            os.mkdir(name, 0o750, dir_fd=fd)
        except FileExistsError:
            pass
        child = None
        try:
            observed = os.stat(name, dir_fd=fd, follow_symlinks=False)
            child = os.open(name, flags, dir_fd=fd)
            held = os.fstat(child)
            _require((observed.st_dev, observed.st_ino) == (held.st_dev, held.st_ino)
                     and _metadata(held) == (1000, 1000, 0o750))
        except OSError as error:
            if error.errno in {errno.ELOOP, errno.ENOTDIR}:
                raise BootstrapError('bootstrap_conflict') from None
            raise
        finally:
            if child is not None:
                os.close(child)
    os.fsync(fd)


def _validated_qbittorrent_config(input_stream):
    _require(input_stream is not None and hasattr(input_stream, 'read'))
    configuration = input_stream.read(4097)
    _require(type(configuration) is bytes and 1 <= len(configuration) <= 4096)
    matching = _QBITTORRENT_PATTERN.fullmatch(configuration)
    _require(matching is not None)
    torrent_port = int(matching.group(1))
    web_port = int(matching.group(5))
    _require(1024 <= torrent_port <= 65535 and 1024 <= web_port <= 65535
             and torrent_port != web_port)
    try:
        salt = base64.b64decode(matching.group(3), validate=True)
        key = base64.b64decode(matching.group(4), validate=True)
    except (ValueError, binascii.Error):
        raise BootstrapError('bootstrap_conflict') from None
    _require(len(salt) == 16 and len(key) == 64)
    return configuration


def _open_child_directory(parent_fd, name):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        return os.open(name, flags, dir_fd=parent_fd)
    except OSError as error:
        if error.errno in {errno.ELOOP, errno.ENOTDIR}:
            raise BootstrapError('bootstrap_conflict') from None
        raise


def _read_bounded(fd):
    pieces = []
    remaining = 4097
    while remaining:
        piece = os.read(fd, remaining)
        if not piece:
            break
        pieces.append(piece)
        remaining -= len(piece)
    result = b''.join(pieces)
    _require(len(result) <= 4096)
    return result


def _open_existing_config(directory_fd):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(_QBITTORRENT_CONFIG, flags, dir_fd=directory_fd)
    except FileNotFoundError:
        return None
    except OSError as error:
        if error.errno in {errno.ELOOP, errno.ENOTDIR}:
            raise BootstrapError('bootstrap_conflict') from None
        raise
    try:
        before = os.fstat(fd)
        _require(stat.S_ISREG(before.st_mode)
                 and before.st_nlink == 1
                 and (before.st_uid, before.st_gid,
                      stat.S_IMODE(before.st_mode)) == (1000, 1000, 0o600))
        content = _read_bounded(fd)
        after = os.fstat(fd)
        _require((before.st_dev, before.st_ino, before.st_size)
                 == (after.st_dev, after.st_ino, after.st_size)
                 and after.st_nlink == 1 and after.st_size == len(content))
        return content
    finally:
        os.close(fd)


def _write_all(fd, content):
    position = 0
    while position < len(content):
        written = os.write(fd, content[position:])
        _require(type(written) is int and written > 0)
        position += written


def _install_qbittorrent_config(root_fd, configuration):
    _require(_metadata(os.fstat(root_fd)) == (1000, 1000, 0o750))
    _require(os.geteuid() == 1000 and os.getegid() == 1000)
    try:
        os.mkdir(_QBITTORRENT_DIRECTORY, 0o750, dir_fd=root_fd)
    except FileExistsError:
        pass
    directory_fd = None
    temporary_fd = None
    try:
        observed_directory = os.stat(
            _QBITTORRENT_DIRECTORY, dir_fd=root_fd, follow_symlinks=False)
        directory_fd = _open_child_directory(root_fd, _QBITTORRENT_DIRECTORY)
        held_directory = os.fstat(directory_fd)
        _require((observed_directory.st_dev, observed_directory.st_ino)
                 == (held_directory.st_dev, held_directory.st_ino)
                 and _metadata(held_directory) == (1000, 1000, 0o750))
        existing = _open_existing_config(directory_fd)
        if existing is not None:
            _require(hmac.compare_digest(existing, configuration))
            return 'qbittorrent_config_already_installed'
        flags = (os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                 | os.O_CLOEXEC)
        try:
            temporary_fd = os.open(
                _QBITTORRENT_TEMP, flags, 0o600, dir_fd=directory_fd)
        except FileExistsError:
            raise BootstrapError('bootstrap_conflict') from None
        metadata = os.fstat(temporary_fd)
        _require(stat.S_ISREG(metadata.st_mode)
                 and metadata.st_nlink == 1
                 and (metadata.st_uid, metadata.st_gid,
                      stat.S_IMODE(metadata.st_mode)) == (1000, 1000, 0o600))
        _write_all(temporary_fd, configuration)
        os.fsync(temporary_fd)
        os.close(temporary_fd)
        temporary_fd = None
        try:
            os.link(_QBITTORRENT_TEMP, _QBITTORRENT_CONFIG,
                    src_dir_fd=directory_fd, dst_dir_fd=directory_fd,
                    follow_symlinks=False)
        except FileExistsError:
            raise BootstrapError('bootstrap_conflict') from None
        os.unlink(_QBITTORRENT_TEMP, dir_fd=directory_fd)
        os.fsync(directory_fd)
        os.fsync(root_fd)
        _require(hmac.compare_digest(
            _open_existing_config(directory_fd), configuration))
        final_directory = os.stat(
            _QBITTORRENT_DIRECTORY, dir_fd=root_fd, follow_symlinks=False)
        _require((final_directory.st_dev, final_directory.st_ino)
                 == (held_directory.st_dev, held_directory.st_ino))
        return 'qbittorrent_config_installed'
    finally:
        if temporary_fd is not None:
            os.close(temporary_fd)
        if directory_fd is not None:
            os.close(directory_fd)


def run(mode, input_stream=None):
    if type(mode) is not str or mode not in _MODES:
        raise BootstrapError('bootstrap_invalid_command')
    configuration = None
    try:
        if mode == 'install_qbittorrent_config':
            configuration = _validated_qbittorrent_config(input_stream)
    except BootstrapError:
        raise
    except (OSError, ValueError, TypeError, OverflowError):
        raise BootstrapError() from None
    fd = None
    try:
        fd = _open_root()
        before = os.fstat(fd)
        if mode == 'install_qbittorrent_config':
            result = _install_qbittorrent_config(fd, configuration)
        elif mode == 'prepare_media_directories':
            _prepare_media_directories(fd)
            result = 'media_directories_prepared'
        elif mode == 'verify_root':
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
        response = {'schemaVersion': 1, 'state': result}
        if configuration is not None:
            response['sha256'] = hashlib.sha256(configuration).hexdigest()
        return response
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
        input_stream = sys.stdin.buffer if args[0] == 'install_qbittorrent_config' else None
        result = run(args[0], input_stream)
    except BootstrapError as error:
        print(error.code, file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
