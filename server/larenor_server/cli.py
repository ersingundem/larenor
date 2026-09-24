import argparse
import sys
import time
from contextlib import nullcontext
from pathlib import Path

import uvicorn

from .config import Settings
from .core_backups.component_restore import ComponentRestorePlanError
from .core_backups.component_restore_runtime import (
    ComponentRestoreRuntimeConfig,
    ComponentRestoreRuntimeError,
    build_component_restore_runtime,
)
from .core_backups.models import validate_backup_passphrase
from .core_backups.restore import restore_empty
from .core_backups.service import MAX_BUNDLE_BYTES
from .errors import ApiError, StartupError
from .files import private_read, private_read_mutable
from .runtime import create_configured_app


def _decode_restore_passphrase(encoded: bytearray) -> str:
    """Decode one bounded secret file and retire its mutable byte buffer."""
    try:
        value = encoded.decode("utf-8")
        if value.endswith("\r\n"):
            value = value[:-2]
        elif value.endswith("\n"):
            value = value[:-1]
        return validate_backup_passphrase(value)
    except (UnicodeError, ValueError):
        raise StartupError("restore_passphrase_invalid") from None
    finally:
        encoded[:] = b"\0" * len(encoded)


def _read_restore_inputs(bundle_path: Path, passphrase_path: Path):
    """Validate the small secret before allocating the bounded bundle."""
    encoded = private_read_mutable(passphrase_path, 514)
    passphrase = _decode_restore_passphrase(encoded)
    return private_read(bundle_path, MAX_BUNDLE_BYTES), passphrase


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Larenor Server API")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8098)
    parser.add_argument("--initialize-only", action="store_true")
    parser.add_argument("--restore", type=Path, metavar="BUNDLE")
    parser.add_argument("--restore-passphrase-file", type=Path, metavar="FILE")
    parser.add_argument("--component-restore-container-journal", type=Path)
    parser.add_argument("--component-restore-volume-journal", type=Path)
    parser.add_argument("--component-restore-engine-socket", type=Path)
    parser.add_argument("--component-restore-recovery-journal", type=Path)
    parser.add_argument("--component-restore-recovery-key-file", type=Path)
    parser.add_argument("--component-restore-engine-uid", type=int)
    args = parser.parse_args(argv)
    if (args.restore is None) != (args.restore_passphrase_file is None):
        parser.error("--restore and --restore-passphrase-file must be used together")
    component_values = (
        args.component_restore_container_journal,
        args.component_restore_volume_journal,
        args.component_restore_engine_socket,
        args.component_restore_recovery_journal,
        args.component_restore_recovery_key_file,
        args.component_restore_engine_uid,
    )
    if any(value is not None for value in component_values) and (
        args.restore is None or any(value is None for value in component_values)
    ):
        parser.error("component restore authority must be complete")
    try:
        settings = Settings.from_environment()
        if args.restore is not None:
            runtime_context = nullcontext(None)
            if all(value is not None for value in component_values):
                config = ComponentRestoreRuntimeConfig(
                    container_journal=args.component_restore_container_journal,
                    volume_journal=args.component_restore_volume_journal,
                    engine_socket=args.component_restore_engine_socket,
                    recovery_journal=args.component_restore_recovery_journal,
                    recovery_key_file=args.component_restore_recovery_key_file,
                    engine_uid=args.component_restore_engine_uid,
                )
                runtime_context = build_component_restore_runtime(config)
            with runtime_context as runtime:
                try:
                    bundle, passphrase = _read_restore_inputs(
                        args.restore,
                        args.restore_passphrase_file,
                    )
                except OSError:
                    raise StartupError("restore_input_unavailable") from None
                try:
                    if runtime is not None:
                        restore_empty(
                            settings,
                            bundle,
                            passphrase,
                            component_runtime=runtime,
                            deadline=time.monotonic() + 300,
                        )
                    else:
                        restore_empty(settings, bundle, passphrase)
                    create_configured_app(settings)
                except OSError:
                    raise StartupError("restore_storage_unavailable") from None
            print("Larenor Core restore completed.")
            return 0
        app = create_configured_app(settings)
    except (
        ApiError,
        ComponentRestorePlanError,
        ComponentRestoreRuntimeError,
        StartupError,
    ) as error:
        print(f"Larenor Server initialization failed: {error}", file=sys.stderr)
        return 1
    if app.state.core.bootstrap_created:
        print(
            f"Administrator bootstrap credentials file: {settings.effective_bootstrap_file}"
        )
    if app.state.publisher_credential_created:
        print(
            f"Client release publishing credential file: {app.state.publisher_credential_file}"
        )
    if args.initialize_only:
        return 0
    uvicorn.run(
        app,
        host=args.host,
        port=args.port,
        workers=1,
        access_log=False,
        proxy_headers=False,
        server_header=False,
        limit_concurrency=32,
        timeout_keep_alive=5,
        h11_max_incomplete_event_size=16384,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
