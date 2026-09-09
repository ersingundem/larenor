"""Versioned public examples for private media bootstrap status."""

import json
from pathlib import Path

from larenor_server.plugins.media_service_bootstrap_models import (
    CreateMediaServiceBootstrapRequest, MediaServiceBootstrap,
    MediaServiceBootstrapsResponse,
)


FIXTURE = Path(__file__).resolve().parents[2] / 'contracts/media-service-bootstraps.v1.json'


def test_media_service_bootstrap_examples_match_strict_models():
    document = json.loads(FIXTURE.read_text())
    assert set(document) == {'createRequest', 'queued', 'history'}
    CreateMediaServiceBootstrapRequest.model_validate(document['createRequest'])
    MediaServiceBootstrap.model_validate(document['queued'])
    MediaServiceBootstrapsResponse.model_validate(document['history'])


def test_public_examples_never_expose_credentials_or_network_authority():
    text = FIXTURE.read_text().lower()
    for forbidden in ('"password":', '"credential":', '"token":', '"apikey":', 'baseurl',
                      'docker.sock', 'hostconfig', 'containerid'):
        assert forbidden not in text
