"""Account-bound Core projection for Jellyfin recent and resume rows."""

import hmac
import time

from ..errors import ApiError
from .jellyfin_media_rows_executor import JellyfinMediaRowsExecutionError
from .media_rows_models import (
    MediaRowsReadback,
    PrivateJellyfinMediaRowsAuthority,
    ReadAccountMediaRowsRequest,
)


class MediaRowsManagement:
    def __init__(self, auth, settings, bindings, bootstraps, backend=None):
        self.auth = auth
        self.settings = settings
        self.bindings = bindings
        self.bootstraps = bootstraps
        self.backend = backend
        self._monotonic = time.monotonic

    def _snapshot(self, actor, body):
        try:
            binding = self.bindings.resolve(
                actor,
                body.installationId,
                body.expectedInstallationRevision,
            )
            bootstrap = self.bootstraps.playback_private(
                body.installationId,
                body.expectedInstallationRevision,
            )
        except ApiError as error:
            if error.status in {401, 403, 409}:
                raise ApiError('media_rows_authority_changed', 409) from None
            raise ApiError('media_rows_worker_unavailable', 503) from None
        if bootstrap.bootstrap_revision != binding.bootstrap_revision:
            raise ApiError('media_rows_authority_changed', 409)
        return binding, bootstrap

    def _retained(self, actor, body, binding, bootstrap):
        try:
            current_binding, current_bootstrap = self._snapshot(actor, body)
            return (
                current_binding.account_id == binding.account_id
                and current_binding.installation_id == binding.installation_id
                and current_binding.installation_revision
                == binding.installation_revision
                and current_binding.binding_revision == binding.binding_revision
                and current_binding.bootstrap_revision
                == binding.bootstrap_revision
                and hmac.compare_digest(
                    current_binding.jellyfin_user_id,
                    binding.jellyfin_user_id,
                )
                and current_bootstrap.bootstrap_revision
                == bootstrap.bootstrap_revision
                and current_bootstrap.plan == bootstrap.plan
                and hmac.compare_digest(
                    current_bootstrap.api_key, bootstrap.api_key
                )
            )
        except Exception:  # noqa: BLE001 - authority callbacks fail closed
            return False

    def read(self, actor, body):
        if type(body) is not ReadAccountMediaRowsRequest:
            raise ApiError('invalid_request')
        if self.backend is None or not callable(
            getattr(self.backend, 'read_media_rows', None)
        ):
            raise ApiError('media_rows_worker_unavailable', 503)
        binding, bootstrap = self._snapshot(actor, body)
        deadline = self._monotonic() + 5
        gate = lambda: self._retained(actor, body, binding, bootstrap)
        if gate() is not True:
            raise ApiError('media_rows_authority_changed', 409)
        private = PrivateJellyfinMediaRowsAuthority(
            requestId=body.requestId,
            installationId=body.installationId,
            installationRevision=body.expectedInstallationRevision,
            bootstrapRevision=binding.bootstrap_revision,
            bindingRevision=binding.binding_revision,
            plan=bootstrap.plan,
            apiKey=bootstrap.api_key,
            userId=binding.jellyfin_user_id,
        )
        try:
            result = self.backend.read_media_rows(
                private, deadline=deadline, gate=gate
            )
            if type(result) is not MediaRowsReadback:
                raise ValueError()
            if self._monotonic() >= deadline:
                raise ApiError('media_rows_worker_unavailable', 503)
            if gate() is not True:
                raise JellyfinMediaRowsExecutionError(
                    'jellyfin_media_rows_authority_changed'
                )
            rows = MediaRowsReadback.model_validate(
                result.model_dump(mode='python', warnings=False)
            )
        except JellyfinMediaRowsExecutionError as error:
            if error.code == 'jellyfin_media_rows_authority_changed':
                raise ApiError('media_rows_authority_changed', 409) from None
            raise ApiError('media_rows_worker_unavailable', 503) from None
        except ApiError:
            raise
        except Exception:  # noqa: BLE001 - private worker details stay private
            raise ApiError('media_rows_worker_unavailable', 503) from None
        return {
            'requestId': body.requestId,
            'installationId': binding.installation_id,
            'installationRevision': binding.installation_revision,
            'bindingRevision': binding.binding_revision,
            'rows': rows,
        }
