"""Authenticated media preparation smoke for the disposable CI container only.

Called after the workflow's bootstrap/private-state restart comparison. Secrets
stay in memory; neither requests nor server responses are included in failures.
No worker, installation or external service operation is invoked.
"""

import hashlib
import json
import re
import secrets
import subprocess
import uuid
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def _base(healthy):
    value = healthy()
    match = re.fullmatch(r"http://127\.0\.0\.1:([0-9]{1,5})/api/v1", value)
    if not match or not 1 <= int(match[1]) <= 65535:
        raise ValueError()
    return value


def _bootstrap(name):
    # The child itself bounds stdout before PIPE captures it. Its command line
    # contains only this fixed reader, never the password or access token.
    reader = "import sys; sys.stdout.buffer.write(open('/data/bootstrap-admin.txt','rb').read(2049))"
    result = subprocess.run(["docker", "exec", name, "python", "-c", reader],
                            check=False, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=10)
    if result.returncode != 0 or len(result.stdout) > 2048:
        raise ValueError()
    match = re.fullmatch(rb"username: admin\npassword: ([!-~]{16,1024})\n", result.stdout)
    if not match:
        raise ValueError()
    return match[1].decode("ascii")


def _verify(name, healthy, platform):
    if (name not in ("larenor-smoke-amd64", "larenor-smoke-arm64")
            or platform != "linux/" + name.removeprefix("larenor-smoke-")):
        raise ValueError()
    base = _base(healthy)
    password = _bootstrap(name)
    opener = build_opener(ProxyHandler({}), _NoRedirect())
    token = None

    def request(method, path, body=None, status=200):
        headers = {"Accept": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        if body is not None:
            headers["Content-Type"] = "application/json"
        data = None if body is None else json.dumps(body).encode("utf-8")
        with opener.open(Request(base + path, data=data, headers=headers, method=method), timeout=5) as response:
            if response.status != status:
                raise ValueError()
            raw = response.read(1048577)
        if len(raw) > 1048576:
            raise ValueError()
        return json.loads(raw)

    initial = request("POST", "/auth/login", {
        "username": "admin", "password": password, "deviceName": "CI container smoke"})
    assert initial["user"]["role"] == "admin" and initial["user"]["mustChangePassword"] is True
    token = initial["accessToken"]
    changed = request("POST", "/auth/password", {
        "currentPassword": password, "newPassword": secrets.token_urlsafe(48)})
    assert changed["user"]["role"] == "admin" and changed["user"]["mustChangePassword"] is False
    token = changed["accessToken"]
    del password, initial, changed
    context = request("GET", "/context")
    assert set(context) == {"schemaVersion", "coreId", "homeId"} and context["schemaVersion"] == 1
    assert all(re.fullmatch(r"[0-9a-f]{32}", context[key]) for key in ("coreId", "homeId"))
    catalog = request("GET", "/admin/plugins/catalog")
    assert request("GET", "/admin/plugins/jobs/capabilities") == {
        "preflightConfigured": False, "installAvailable": False}
    assert request("GET", "/admin/plugins/jobs") == {"jobs": [], "nextBefore": None}
    body = {"requestId": uuid.uuid4().hex, "templateId": "media", "context": context,
            "catalogDigest": catalog["catalogDigest"], "platform": platform,
            "settings": {"instanceName": "larenor", "dataRootId": "appdata",
                         "libraryRootId": "library", "musicRootId": None}}
    record = request("POST", "/admin/media/preparations", body, status=201)["preparation"]
    assert re.fullmatch(r"[0-9a-f]{32}", record["id"])
    assert record["requestId"] == body["requestId"] and record["revision"] == 1 and record["state"] == "prepared"
    plan = record["plan"]
    assert (plan["preparationId"] == record["id"] and plan["coreId"] == context["coreId"]
            and plan["homeId"] == context["homeId"] and plan["platform"] == platform
            and plan["catalogDigest"] == catalog["catalogDigest"] and plan["settings"] == body["settings"])
    assert plan["installAvailable"] is False and plan["bootstrapExposure"] == "unverified"
    canonical = json.dumps({k: v for k, v in plan.items() if k != "planHash"},
                           sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    assert hashlib.sha256(canonical).hexdigest() == plan["planHash"]
    assert [c["serviceId"] for c in plan["components"]] == [
        "qbittorrent", "sonarr", "radarr", "jellyfin", "seerr", "music_assistant"]
    for component in plan["components"]:
        assert component["plan"]["installable"] is False
        assert component["plan"]["image"]["platform"] == platform
        assert [step["kind"] for step in component["steps"]] == [
            "prepare_storage", "create_container", "start_container", "bootstrap", "verify_service"]
    # A restart must retain the original session, Core identity and full plan,
    # and may change the loopback port assigned by Docker.
    subprocess.run(["docker", "restart", "--time", "10", name], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    base = _base(healthy)
    assert request("GET", "/context") == context
    assert request("GET", "/admin/media/preparations") == {"preparations": [record], "nextBefore": None}
    path = "/admin/media/preparations/" + record["id"]
    assert request("GET", path) == {"preparation": record}
    cancelled = request("POST", path + "/cancel", {"expectedRevision": record["revision"]})["preparation"]
    assert cancelled["state"] == "cancelled" and cancelled["revision"] == 2
    assert {k: v for k, v in cancelled.items() if k not in ("state", "revision", "updatedAt")} == {
        k: v for k, v in record.items() if k not in ("state", "revision", "updatedAt")}
    assert cancelled["updatedAt"] >= record["updatedAt"]
    assert request("GET", path) == {"preparation": cancelled}
    assert request("GET", "/admin/media/preparations") == {"preparations": [cancelled], "nextBefore": None}
    assert request("GET", "/admin/plugins/jobs") == {"jobs": [], "nextBefore": None}


def verify_media_preparation(name, healthy, platform):
    """Raise one static failure; never echo credential-bearing HTTP diagnostics."""
    try:
        _verify(name, healthy, platform)
    except Exception:
        raise RuntimeError("Media preparation smoke failed") from None
