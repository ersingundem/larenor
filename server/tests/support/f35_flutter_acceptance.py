"""Run the F35 Flutter client through normal Core and real OCR executables."""

import base64
from pathlib import Path
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

from fastapi.testclient import TestClient
import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import Clock, auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from support.f35_ocr_fixture import executable, warranty_pdf


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f35-client-") as name:
        root = Path(name).resolve()
        clock = Clock()
        settings = Settings(
            root / "data", root / "secrets/vault.key", clock=clock,
            login_ip_limit=100, login_account_limit=100, login_global_limit=100,
            home_document_tesseract=executable(
                "LARENOR_TEST_TESSERACT", "tesseract"
            ),
            home_document_pdftoppm=executable(
                "LARENOR_TEST_PDFTOPPM", "pdftoppm"
            ),
        )
        app = create_app(settings)
        fixture = TestClient(app)
        fixture.__enter__()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        running = uvicorn.Server(
            uvicorn.Config(app, log_level="critical", access_log=False)
        )
        thread = threading.Thread(
            target=lambda: running.run(sockets=[listener]), daemon=True
        )
        try:
            admin = ready((app, fixture, settings, clock))
            scope = app.state.core.context
            resource = fixture.post(
                f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
                headers=auth(admin),
                json={"kind": "resource", "label": "Warranty PDF", "order": 0},
            ).json()["record"]
            inventory = fixture.post(
                f"/api/v1/inventory/{scope.coreId}/{scope.homeId}/items",
                headers=auth(admin),
                json={
                    "schemaVersion": 1, "label": "Fridge", "roomId": None,
                    "deviceId": None, "documentIds": [], "readerIds": [],
                },
            ).json()["item"]
            thread.start()
            deadline = time.monotonic() + 5
            while not running.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError("isolated_core_startup_failed")
                time.sleep(0.02)
            result = subprocess.run(
                [
                    "flutter", "test",
                    "test/features/home_documents/home_document_ocr_normal_core_test.dart",
                ],
                cwd=Path(__file__).resolve().parents[3], check=False,
                env={
                    **os.environ,
                    "LARENOR_F35_CORE_URL":
                        f"http://127.0.0.1:{listener.getsockname()[1]}",
                    "LARENOR_F35_TOKEN": admin["accessToken"],
                    "LARENOR_F35_CORE_ID": scope.coreId,
                    "LARENOR_F35_HOME_ID": scope.homeId,
                    "LARENOR_F35_ACCOUNT_ID": admin["user"]["id"],
                    "LARENOR_F35_RESOURCE_ID": resource["ref"]["id"],
                    "LARENOR_F35_INVENTORY_ID": inventory["ref"]["id"],
                    "LARENOR_F35_PDF": base64.b64encode(warranty_pdf()).decode("ascii"),
                },
                timeout=90,
            )
            return result.returncode
        finally:
            running.should_exit = True
            if thread.is_alive():
                thread.join(timeout=5)
            listener.close()
            fixture.__exit__(None, None, None)


if __name__ == "__main__":
    sys.exit(main())
