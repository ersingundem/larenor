import argparse
import sys
from pathlib import Path

import uvicorn

from .config import Settings
from .core_backups.models import validate_backup_passphrase
from .core_backups.restore import restore_empty
from .core_backups.service import MAX_BUNDLE_BYTES
from .errors import ApiError, StartupError
from .files import private_read
from .runtime import create_configured_app


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Larenor Server API")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8098)
    parser.add_argument("--initialize-only", action="store_true")
    parser.add_argument("--restore", type=Path, metavar="BUNDLE")
    parser.add_argument("--restore-passphrase-file", type=Path, metavar="FILE")
    args = parser.parse_args(argv)
    if (args.restore is None) != (args.restore_passphrase_file is None):
        parser.error("--restore and --restore-passphrase-file must be used together")
    try:
        settings = Settings.from_environment()
        if args.restore is not None:
            try:
                bundle = private_read(args.restore, MAX_BUNDLE_BYTES)
                encoded = private_read(args.restore_passphrase_file, 513)
            except OSError:
                raise StartupError("restore_input_unavailable") from None
            try:
                passphrase = validate_backup_passphrase(
                    encoded.decode("utf-8").removesuffix("\n")
                )
            except (UnicodeError, ValueError):
                raise StartupError("restore_passphrase_invalid") from None
            try:
                restore_empty(settings, bundle, passphrase)
                create_configured_app(settings)
            except OSError:
                raise StartupError("restore_storage_unavailable") from None
            print("Larenor Core restore completed.")
            return 0
        app = create_configured_app(settings)
    except (ApiError, StartupError) as error:
        print(f"Larenor Server initialization failed: {error}", file=sys.stderr)
        return 1
    if app.state.core.bootstrap_created:
        print(f"Administrator bootstrap credentials file: {settings.effective_bootstrap_file}")
    if app.state.publisher_credential_created:
        print(f"Client release publishing credential file: {app.state.publisher_credential_file}")
    if args.initialize_only:
        return 0
    uvicorn.run(app, host=args.host, port=args.port, workers=1, access_log=False,
                proxy_headers=False, server_header=False, limit_concurrency=32,
                timeout_keep_alive=5, h11_max_incomplete_event_size=16384)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
