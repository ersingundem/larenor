"""Compose the packaged Server APIs without loading arbitrary runtime plugins."""

import os
from pathlib import Path
import secrets

from .app import create_app
from .config import Settings
from .errors import ApiError, StartupError
from .files import checked_path, private_create, private_directory, private_read
from .releases import JavaApkVerifier, ReleaseService, ReleaseSettings, build_release_router
from .releases.models import PUBLISH_TOKEN


# Public certificate of Larenor Client; no private signing material is bundled.
DEFAULT_CLIENT_SIGNER = "d7c8be0fd89daa2d60aa97a249aa1e3615aed92fcb7e4135bbbd7456eb5882a0"


def create_configured_app(settings: Settings):
    """Normal entry point: accounts, administration, vault and Client releases.

    Publication has its own locally generated credential. Missing verifier
    binaries disable publication with an explicit error, never verification.
    """
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
        app.include_router(build_release_router(releases), prefix="/api/v1")
        app.state.releases = releases
        app.state.publisher_credential_created = created
        app.state.publisher_credential_file = publisher_file
        return app
    except (OSError, UnicodeError, ApiError):
        raise StartupError("runtime_storage_unavailable") from None
