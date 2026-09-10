"""One closed decoder shared by migration and live command/history reads."""
from .models import LegacyStoredCommand, StoredCommand


def command_aad(row):
    return f'larenor-ha-command-v1:{row["request_id"]}:{row["resource_id"]}'.encode('ascii')


def decode_command(row, cipher, scope, *, legacy=False):
    model = LegacyStoredCommand if legacy else StoredCommand
    value = model.model_validate_json(cipher.decrypt(row['nonce'], row['ciphertext'], command_aad(row)))
    receipt, request = value.receipt, value.request
    if (request.requestId != row['request_id'] or receipt.requestId != row['request_id'] or
            receipt.ref.id != row['resource_id'] or receipt.ref.kind != 'resource' or
            (receipt.ref.coreId, receipt.ref.homeId) != (scope.coreId, scope.homeId) or
            receipt.action != request.action or receipt.bindingRevision != request.expectedBindingRevision):
        raise ValueError('invalid_command_storage')
    return value
