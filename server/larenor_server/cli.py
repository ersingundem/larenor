import argparse
import sys

import uvicorn

from .runtime import create_configured_app
from .config import Settings
from .errors import StartupError


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Larenor Server API")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8098)
    parser.add_argument("--initialize-only", action="store_true")
    args = parser.parse_args(argv)
    try:
        settings = Settings.from_environment()
        app = create_configured_app(settings)
    except StartupError as error:
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
