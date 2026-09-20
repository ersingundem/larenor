"""Least-privilege private input for Seerr bootstrap."""

import pytest
from pydantic import ValidationError

from larenor_server.plugins.seerr_bootstrap_models import (
    PINNED_ARR_HD_1080P_PROFILE_ID,
    PrivateSeerrArrBinding,
    PrivateSeerrBootstrap,
)


SECRET = "S" * 48


def arr_binding(service, profile_id=PINNED_ARR_HD_1080P_PROFILE_ID):
    identifier = "b" if service == "radarr" else "c"
    return PrivateSeerrArrBinding(
        serviceId=service,
        configurationId=identifier * 32,
        configurationRevision=1,
        resourceRevision=1,
        serviceRevision=1,
        configurationDigest=identifier * 64,
        hostname="larenor-" + identifier * 32,
        apiKey=identifier * 32,
        rootPath="/data/movies" if service == "radarr" else "/data/shows",
        profileId=profile_id,
        profileName="HD-1080p",
    )


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


def test_private_model_pins_both_arr_services_to_their_shipped_hd_profile():
    value = PrivateSeerrBootstrap(
        credential=SECRET,
        sourceBootstrapId="a" * 32,
        sourceBootstrapRevision=3,
        arrBindings=(arr_binding("radarr"), arr_binding("sonarr")),
    )
    assert tuple(item.profileId for item in value.arrBindings) == (4, 4)

    with pytest.raises(ValidationError, match="invalid_seerr_arr_bindings"):
        PrivateSeerrBootstrap(
            credential=SECRET,
            sourceBootstrapId="a" * 32,
            sourceBootstrapRevision=3,
            arrBindings=(arr_binding("radarr"), arr_binding("sonarr", 5)),
        )


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
