"""Linux component restore boundaries bound to durable installation receipts."""

import hashlib
import json

from .component_installation_authority import (
    DurableComponentInstallationAuthority,
)
from .component_restore import (
    ComponentRestoreAuthorityTarget,
    ComponentRestoreAuthorityVolume,
    ComponentRestorePlanError,
)


def _canonical(value):
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("ascii")


def _digest(value):
    return hashlib.sha256(_canonical(value)).hexdigest()


def _volume_identity(receipt):
    intent = receipt.intent
    binding = intent.binding
    resource = binding.resource
    return {
        "volumeId": receipt.volume_id,
        "target": receipt.target,
        "journalId": binding.journal_id,
        "ownershipNonce": binding.ownership_nonce,
        "resourceId": resource.resourceId,
        "operationId": resource.operationId,
        "name": resource.name,
        "revision": intent.receipt.revision,
    }


def _installation_identity(receipt):
    installed = receipt.installed
    binding = installed.binding
    return {
        "serviceId": receipt.service_id,
        "installationId": receipt.installation_id,
        "containerId": receipt.container_id,
        "serviceVersion": receipt.service_version,
        "configSchemaVersion": receipt.config_schema_version,
        "dataSchemaVersion": receipt.data_schema_version,
        "journalId": installed.journal_id,
        "jobId": installed.job_id,
        "createDispatchId": installed.create_dispatch_id,
        "startDispatchId": installed.start_dispatch_id,
        "platform": binding.platform,
        "imageId": binding.image_id,
        "networkId": binding.network_id,
        "mounts": [
            {
                "name": item.name,
                "target": item.target,
                "readOnly": item.read_only,
            }
            for item in binding.mounts
        ],
        "specificationSha256": hashlib.sha256(binding.specification).hexdigest(),
        "imageConfigurationSha256": hashlib.sha256(
            binding.image_configuration
        ).hexdigest(),
        "volumes": [_volume_identity(item) for item in receipt.volumes],
    }


def _revision(receipt):
    value = int(_digest(_installation_identity(receipt))[:16], 16)
    return max(1, value & (2**63 - 1))


class DurableComponentRestoreAuthority:
    """Expose exact restore targets without paths, payloads or credentials."""

    def __init__(self, authority):
        if type(authority) is not DurableComponentInstallationAuthority:
            raise ComponentRestorePlanError()
        self._authority = authority

    @staticmethod
    def _target(receipt):
        return ComponentRestoreAuthorityTarget(
            service_id=receipt.service_id,
            installation_id=receipt.installation_id,
            service_version=receipt.service_version,
            config_schema_version=receipt.config_schema_version,
            data_schema_version=receipt.data_schema_version,
            installation_revision=_revision(receipt),
            volumes=tuple(
                ComponentRestoreAuthorityVolume(
                    volume_id=volume.volume_id,
                    binding_id=_digest(_volume_identity(volume)),
                    binding_revision=volume.intent.receipt.revision,
                )
                for volume in receipt.volumes
            ),
        )

    def snapshot(self):
        try:
            receipts = self._authority.snapshot()
            return tuple(self._target(item) for item in receipts)
        except ComponentRestorePlanError:
            raise
        except Exception:
            raise ComponentRestorePlanError() from None

