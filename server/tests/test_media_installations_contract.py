"""Versioned public examples for the bounded media installation API."""

import json
from pathlib import Path

from larenor_server.plugins.media_installation_models import (
    CancelMediaInstallationRequest,
    CreateMediaInstallationRequest,
    MediaInstallation,
    MediaInstallationCapabilities,
    MediaInstallationsResponse,
)


FIXTURE = Path(__file__).resolve().parents[2] / 'contracts/media-installations.v1.json'


def test_media_installation_examples_match_the_strict_public_models():
    document = json.loads(FIXTURE.read_text())
    assert set(document) == {
        'capabilities', 'createRequest', 'queued', 'containerStarted',
        'cancelRequest', 'cancelled', 'history',
    }
    MediaInstallationCapabilities.model_validate(document['capabilities'])
    CreateMediaInstallationRequest.model_validate(document['createRequest'])
    CancelMediaInstallationRequest.model_validate(document['cancelRequest'])
    for name in ('queued', 'containerStarted', 'cancelled'):
        MediaInstallation.model_validate(document[name])
    MediaInstallationsResponse.model_validate(document['history'])


def test_public_examples_never_expose_worker_or_docker_authority():
    text = FIXTURE.read_text()
    for forbidden in ('HostConfig', 'docker.sock', 'containerId', 'hostPath', 'command'):
        assert forbidden not in text
