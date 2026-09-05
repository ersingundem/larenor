"""Real loopback HTTP against Uvicorn; all credentials/data are temporary fixtures."""

import socket
import threading
import time

import httpx
import uvicorn

from conftest import bootstrap_password, document


def test_real_http_login_change_password_vault_refresh_logout(server):
    app, _in_process_client, settings, _clock = server
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(128)
    port = listener.getsockname()[1]
    engine = uvicorn.Server(uvicorn.Config(app, log_level="critical", access_log=False,
                                         proxy_headers=False, lifespan="off"))
    worker = threading.Thread(target=lambda: engine.run(sockets=[listener]), daemon=True)
    worker.start()
    try:
        deadline = time.monotonic() + 5
        while not engine.started and worker.is_alive() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert engine.started
        with httpx.Client(base_url=f"http://127.0.0.1:{port}", timeout=3, trust_env=False) as client:
            assert client.get("/api/v1/health").json() == {"service": "larenor-server", "apiVersion": 1}
            password = bootstrap_password(settings)
            response = client.post("/api/v1/auth/login", json={"username": "admin", "password": password,
                                                             "deviceName": "Synthetic DeX client"})
            assert response.status_code == 200
            initial = response.json()
            headers = {"Authorization": "Bearer " + initial["accessToken"]}
            assert client.get("/api/v1/vault", headers=headers).status_code == 403
            response = client.post("/api/v1/auth/password", headers=headers,
                                   json={"currentPassword": password, "newPassword": "HTTP synthetic password 2026"})
            assert response.status_code == 200
            pair = response.json()
            headers = {"Authorization": "Bearer " + pair["accessToken"]}
            stored = client.put("/api/v1/vault", headers=headers,
                                json={"expectedRevision": 0, "document": document()})
            assert stored.status_code == 200
            assert client.get("/api/v1/vault", headers=headers).json() == stored.json()
            refreshed = client.post("/api/v1/auth/refresh", json={"refreshToken": pair["refreshToken"]})
            assert refreshed.status_code == 200
            headers = {"Authorization": "Bearer " + refreshed.json()["accessToken"]}
            assert client.post("/api/v1/auth/logout", headers=headers).status_code == 204
            assert client.get("/api/v1/auth/me", headers=headers).status_code == 401
            assert not settings.effective_bootstrap_file.exists()
    finally:
        engine.should_exit = True
        worker.join(timeout=5)
        listener.close()
        assert not worker.is_alive()
