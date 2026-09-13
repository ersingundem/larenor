"""Least-privilege private input for Seerr bootstrap."""

import pytest
from pydantic import ValidationError

from larenor_server.plugins.seerr_bootstrap_models import PrivateSeerrBootstrap


SECRET = "S" * 48


def test_private_model_carries_only_credential_and_source_receipt_identity():
    value = PrivateSeerrBootstrap(
        credential=SECRET,
        sourceBootstrapId="a" * 32,
        sourceBootstrapRevision=3,
    )
    assert value.model_dump() == {
        "schemaVersion": 1,
        "username": "larenor-system",
        "credential": SECRET,
        "sourceBootstrapId": "a" * 32,
        "sourceBootstrapRevision": 3,
        "arrBindings": (),
    }
    assert SECRET not in repr(value)


@pytest.mark.parametrize(
    "change",
    [
        {"credential": "short"},
        {"username": "foreign"},
        {"sourceBootstrapId": "not-an-id"},
        {"sourceBootstrapRevision": True},
        {"unexpected": "private"},
    ],
)
def test_private_model_rejects_unbound_or_extra_input(change):
    body = {
        "credential": SECRET,
        "sourceBootstrapId": "a" * 32,
        "sourceBootstrapRevision": 3,
    }
    body.update(change)
    with pytest.raises(ValidationError):
        PrivateSeerrBootstrap.model_validate(body)
