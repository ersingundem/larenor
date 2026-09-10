"""Encrypted, short-lived, single-consumer playback credential leases."""

import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import time

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import Field

from ..admin.models import ObjectId
from ..files import checked_path, private_directory, sync_directory
from ..models import StrictModel
from .music_playback_models import PrivateMusicAssistantServiceBinding
from .music_target_effect_models import MusicTargetEffectEnvelope


MAX_LEASE = 16384


class MusicTargetCredentialLeaseError(Exception):
    """Static lease error without filesystem, token, or endpoint details."""


class _Lease(StrictModel):
    executionId: ObjectId
    effectDigest: str = Field(pattern=r'^[0-9a-f]{64}$')
    issuedAt: float
    expiresAt: float
    binding: PrivateMusicAssistantServiceBinding = Field(repr=False)


class MusicTargetCredentialLeaseStore:
    def __init__(self, root, key, *, clock=time.time):
        try:
            self.root = checked_path(Path(root).absolute())
            private_directory(self.root)
            if type(key) is not bytes or len(key) != 32 or not callable(clock):
                raise ValueError()
            self._cipher, self.clock = AESGCM(key), clock
        except Exception:
            raise MusicTargetCredentialLeaseError('music_target_lease_unavailable') from None

    @staticmethod
    def _digest(action):
        if type(action) is not MusicTargetEffectEnvelope:
            raise MusicTargetCredentialLeaseError('music_target_lease_invalid')
        return hashlib.sha256(action.model_dump_json().encode()).hexdigest()

    def _path(self, execution_id):
        if type(execution_id) is not str or len(execution_id) != 32:
            raise MusicTargetCredentialLeaseError('music_target_lease_invalid')
        return self.root / (execution_id + '.lease')

    @staticmethod
    def _aad(execution_id):
        return ('larenor:music-target-lease:v1:' + execution_id).encode('ascii')

    def issue(self, action, binding, *, expires_at):
        now = self.clock()
        if (type(binding) is not PrivateMusicAssistantServiceBinding
                or binding.installationId != action.installationId
                or binding.installationRevision != action.installationRevision
                or binding.coreRevision != action.coreRevision
                or type(now) not in (int, float)
                or type(expires_at) not in (int, float)
                or not now < expires_at <= now + 5):
            raise MusicTargetCredentialLeaseError('music_target_lease_invalid')
        lease = _Lease(
            executionId=action.executionId, effectDigest=self._digest(action),
            issuedAt=now, expiresAt=expires_at, binding=binding)
        nonce = os.urandom(12)
        encrypted = self._cipher.encrypt(
            nonce, lease.model_dump_json().encode(), self._aad(action.executionId))
        body = nonce + encrypted
        if len(body) > MAX_LEASE:
            raise MusicTargetCredentialLeaseError('music_target_lease_invalid')
        path = self._path(action.executionId)
        temporary = self.root / ('.' + path.name + '.' + secrets.token_hex(12))
        descriptor = None
        try:
            descriptor = os.open(
                temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600)
            with os.fdopen(descriptor, 'wb') as stream:
                descriptor = None
                stream.write(body)
                stream.flush()
                os.fsync(stream.fileno())
            if path.exists() or path.is_symlink():
                raise MusicTargetCredentialLeaseError('music_target_lease_replayed')
            os.replace(temporary, path)
            sync_directory(self.root)
        except MusicTargetCredentialLeaseError:
            raise
        except Exception:
            raise MusicTargetCredentialLeaseError('music_target_lease_unavailable') from None
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass

    def consume(self, action):
        path = self._path(action.executionId)
        descriptor = None
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise ValueError()
            with os.fdopen(descriptor, 'rb') as stream:
                descriptor = None
                raw = stream.read(MAX_LEASE + 1)
            path.unlink()
            sync_directory(self.root)
            if not 29 <= len(raw) <= MAX_LEASE:
                raise ValueError()
            lease = _Lease.model_validate_json(self._cipher.decrypt(
                raw[:12], raw[12:], self._aad(action.executionId)))
            now = self.clock()
            if (lease.executionId != action.executionId
                    or lease.effectDigest != self._digest(action)
                    or type(now) not in (int, float)
                    or now < lease.issuedAt or now >= lease.expiresAt
                    or lease.expiresAt - lease.issuedAt > 5):
                raise ValueError()
            return lease.binding
        except MusicTargetCredentialLeaseError:
            raise
        except Exception:
            raise MusicTargetCredentialLeaseError('music_target_lease_unavailable') from None
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def retire(self, execution_id):
        try:
            self._path(execution_id).unlink()
            sync_directory(self.root)
        except FileNotFoundError:
            pass
        except Exception:
            raise MusicTargetCredentialLeaseError('music_target_lease_unavailable') from None
