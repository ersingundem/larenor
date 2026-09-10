"""Live binding to one private Music Assistant worker incarnation."""

import json
import os
from pathlib import Path
import socket
import stat

from pydantic import Field

from ..admin.models import ObjectId
from ..files import checked_path, private_read
from ..models import StrictModel
from .preflight_ipc import _peer_uid


MAX_HEALTH = 2048


class MusicTargetWorkerHealthError(Exception):
    """Static health error without paths or worker details."""


class MusicTargetWorkerHealthBinding(StrictModel):
    sessionId: ObjectId
    attempt: int = Field(ge=1, le=3)
    socketDevice: int = Field(ge=0)
    socketInode: int = Field(ge=1)
    socketUid: int = Field(ge=0, le=2**31 - 1)


class MusicTargetWorkerHealthGuard:
    def __init__(self, socket_path, health_path, *, owner_uid=0,
                 peer_uid=None, timeout=.25):
        try:
            self.socket_path = checked_path(Path(socket_path).absolute())
            self.health_path = checked_path(Path(health_path).absolute())
            if (self.socket_path == self.health_path
                    or type(owner_uid) is not int or owner_uid < 0
                    or type(timeout) not in (int, float) or not 0 < timeout <= 1):
                raise ValueError()
            self.owner_uid, self.peer_uid = owner_uid, peer_uid or _peer_uid
            self.timeout = timeout
        except Exception:
            raise MusicTargetWorkerHealthError('music_worker_health_unavailable') from None

    def _receipt(self):
        try:
            value = json.loads(private_read(self.health_path, MAX_HEALTH))
            if (type(value) is not dict or set(value) != {
                    'schemaVersion', 'component', 'state', 'attempt',
                    'effectAvailable', 'installAvailable', 'sessionId',
                    'socketDevice', 'socketInode', 'socketUid'}
                    or value['schemaVersion'] != 1
                    or value['component'] != 'music_target_effect_worker'
                    or value['state'] != 'ready'
                    or value['effectAvailable'] is not True
                    or value['installAvailable'] is not False):
                raise ValueError()
            return MusicTargetWorkerHealthBinding.model_validate({
                key: value[key] for key in (
                    'sessionId', 'attempt', 'socketDevice', 'socketInode',
                    'socketUid')})
        except Exception:
            raise MusicTargetWorkerHealthError('music_worker_health_unavailable') from None

    def _live(self):
        connection = None
        try:
            before = self.socket_path.lstat()
            if (not stat.S_ISSOCK(before.st_mode) or before.st_uid != self.owner_uid
                    or stat.S_IMODE(before.st_mode) != 0o600):
                raise ValueError()
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(self.timeout)
            connection.connect(str(self.socket_path))
            if self.peer_uid(connection) != self.owner_uid:
                raise ValueError()
            after = self.socket_path.lstat()
            if ((after.st_dev, after.st_ino, after.st_uid, after.st_mode)
                    != (before.st_dev, before.st_ino, before.st_uid, before.st_mode)):
                raise ValueError()
            return before
        except Exception:
            raise MusicTargetWorkerHealthError('music_worker_health_unavailable') from None
        finally:
            if connection is not None:
                connection.close()

    def bind(self):
        receipt, info = self._receipt(), self._live()
        if (receipt.socketDevice, receipt.socketInode, receipt.socketUid) != (
                info.st_dev, info.st_ino, info.st_uid):
            raise MusicTargetWorkerHealthError('music_worker_health_unavailable')
        return receipt

    def check(self, binding):
        if (type(binding) is not MusicTargetWorkerHealthBinding
                or self.bind() != binding):
            raise MusicTargetWorkerHealthError('music_worker_health_unavailable')
