"""Compose the packaged Server APIs without loading arbitrary runtime plugins."""

import os
import secrets
from pathlib import Path

from .app import create_app
from .config import Settings
from .errors import ApiError, StartupError
from .files import checked_path, private_create, private_directory, private_read
from .releases import (
    BetaReleaseSynchronizer,
    GitHubBetaSource,
    JavaApkVerifier,
    ReleaseService,
    ReleaseSettings,
    build_release_router,
)
from .releases.models import PUBLISH_TOKEN, validate_manifest

# Public certificate of Larenor Client; no private signing material is bundled.
DEFAULT_CLIENT_SIGNER = "d7c8be0fd89daa2d60aa97a249aa1e3615aed92fcb7e4135bbbd7456eb5882a0"


def _verified_rollout_release(releases: ReleaseService, channel: str) -> dict | None:
    """Require an exact downloadable APK before marking a rollout ready."""
    candidate = releases.latest(channel)
    if candidate is None:
        return None
    expected = validate_manifest(candidate)
    actual, stream = releases.open_apk(expected["versionCode"])
    try:
        if validate_manifest(actual) != expected:
            raise ApiError("server_unavailable", 503)
        return actual
    finally:
        stream.close()


def create_configured_app(settings: Settings):
    """Normal entry point: accounts, administration, vault and Client releases.

    Publication has its own locally generated credential. Missing verifier
    binaries disable publication with an explicit error, never verification.
    """
    try:
        beta_poll = int(os.environ.get("LARENOR_BETA_POLL_SECONDS", "900"))
        beta_max_age = int(os.environ.get("LARENOR_BETA_MAX_AGE_SECONDS", "1209600"))
    except ValueError:
        raise StartupError("invalid_beta_source_settings") from None
    if not 60 <= beta_poll <= 3600:
        raise StartupError("invalid_beta_source_settings")
    beta_source = GitHubBetaSource(
        clock=settings.clock,
        repository=os.environ.get("LARENOR_BETA_SOURCE_REPOSITORY", "ersingundem/larenor"),
        max_age_seconds=beta_max_age,
    )
    publisher_file = Path(os.environ.get(
        "LARENOR_PUBLISHER_TOKEN_FILE", str(settings.key_file.parent / "publisher.token")))
    if not publisher_file.is_absolute():
        raise StartupError("publisher_path_invalid")
    checked_path(publisher_file)
    checked_path(settings.data_dir)
    if publisher_file.is_relative_to(settings.data_dir):
        raise StartupError("publisher_credential_must_be_outside_data_directory")
    try:
        # Check source/core before creating the additional publishing credential.
        app = create_app(settings)
        private_directory(publisher_file.parent)
        created = False
        try:
            private_create(publisher_file, ("lpub_" + secrets.token_urlsafe(32) + "\n").encode())
            created = True
        except FileExistsError:
            pass
        token = private_read(publisher_file, 49).decode("ascii").rstrip("\n")
        if not PUBLISH_TOKEN.fullmatch(token):
            raise StartupError("publisher_credential_invalid")
        releases = ReleaseService(
            ReleaseSettings(
                data_dir=Path(os.environ.get("LARENOR_RELEASE_DIR", str(settings.data_dir / "releases"))),
                signer_sha256=os.environ.get("LARENOR_CLIENT_SIGNER_SHA256", DEFAULT_CLIENT_SIGNER),
                publisher_token_file=publisher_file,
                clock=settings.clock,
            ),
            verifier=JavaApkVerifier(
                java=Path(os.environ.get("LARENOR_JAVA", "/usr/bin/java")),
                jar=Path(os.environ.get("LARENOR_APKSIG_JAR", "/opt/larenor/verifier/apksig.jar")),
                classes=Path(os.environ.get("LARENOR_APKSIG_CLASSES", "/opt/larenor/verifier/classes")),
            ),
        )
        app.state.core.tablet_fleet.bind_release_catalog(
            lambda channel: _verified_rollout_release(releases, channel),
            releases.settings.signer_sha256,
        )
        beta_releases = BetaReleaseSynchronizer(
            releases,
            beta_source,
            clock=settings.clock,
            poll_seconds=beta_poll,
        )
        app.include_router(build_release_router(releases, beta=beta_releases), prefix="/api/v1")
        app.state.releases = releases
        app.state.beta_releases = beta_releases
        app.state.publisher_credential_created = created
        app.state.publisher_credential_file = publisher_file
        return app
    except (OSError, UnicodeError, ApiError):
        raise StartupError("runtime_storage_unavailable") from None
