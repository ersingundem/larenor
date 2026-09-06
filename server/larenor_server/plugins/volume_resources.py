"""Unwired private volume observations; no execution or ownership grant."""


class VolumeResourceError(Exception):
    def __init__(self, code='volume_protocol'):
        self.code = code if code in {
            'invalid_volume_binding', 'volume_protocol', 'volume_response_limit',
            'volume_conflict',
        } else 'volume_protocol'
        super().__init__(self.code)


def volume_binding(plan, stack, catalog, policy, resource_id, *, journal_id, ownership_nonce):
    raise VolumeResourceError('invalid_volume_binding')


def volume_inspect_target(binding):
    raise VolumeResourceError('invalid_volume_binding')


def volume_expected_labels(binding):
    raise VolumeResourceError('invalid_volume_binding')


def validate_volume_inspect(response, binding, *, request_target):
    raise VolumeResourceError('volume_protocol')
