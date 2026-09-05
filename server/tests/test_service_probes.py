"""Read-only service probes: all replies are synthetic, with no network calls."""

import json

import pytest

from larenor_server.services import probe
from larenor_server.services.probe import ProbeResult, probe_connection
from larenor_server.services.service import ServiceConnection
from larenor_server.services.transport import ProbeResponse, ProbeTransportError


def connection(kind="home_assistant", credentials=None, base_url="https://service.test/prefix"):
    return ServiceConnection("a" * 32, "Private service", kind, base_url, 1, credentials or {})


def reply(value=None, status=200, headers=()):
    body = value if isinstance(value, bytes) else json.dumps(value).encode()
    return ProbeResponse(status, tuple(headers), body)


class FakeFactory:
    def __init__(self, *responses, clock=None, durations=()):
        self.responses = list(responses)
        self.calls = []
        self.instances = []
        self.clock = clock
        self.durations = list(durations)

    def __call__(self, base_url, **options):
        factory = self

        class FakeTransport:
            closed = False

            def request(self, method, path, headers=None, body=None):
                factory.calls.append((base_url, method, path, dict(headers or {}), body, options))
                if factory.clock is not None and factory.durations:
                    factory.clock[0] += factory.durations.pop(0)
                result = factory.responses.pop(0)
                if isinstance(result, Exception):
                    raise result
                return result

            def close(self):
                self.closed = True

        instance = FakeTransport()
        self.instances.append(instance)
        return instance


@pytest.mark.parametrize("kind,credentials,path,payload,header,version", [
    ("home_assistant", {"token": "private-ha"}, "/api/config", {"version": "2026.9.0", "components": ["api"]}, ("Authorization", "Bearer private-ha"), "2026.9.0"),
    *[(kind, {"apiKey": "private-arr"}, f"/api/{api}/system/status", {"appName": kind.title(), "version": "6.0.1"}, ("X-Api-Key", "private-arr"), "6.0.1")
      for kind, api in [("sonarr", "v3"), ("radarr", "v3"), ("lidarr", "v1"), ("readarr", "v1"), ("prowlarr", "v1")]],
    ("bazarr", {"apiKey": "private-baz"}, "/api/system/status", {"data": {"bazarr_version": "1.5.0"}}, ("X-Api-Key", "private-baz"), "1.5.0"),
    ("seerr", {"apiKey": "private-seerr"}, "/api/v1/auth/me", {"id": 1, "permissions": 2}, ("X-Api-Key", "private-seerr"), None),
    ("jellyfin", {"token": "private-jelly"}, "/System/Info", {"ProductName": "Jellyfin Server", "Version": "10.11.0", "StartupWizardCompleted": True}, ("X-Emby-Token", "private-jelly"), "10.11.0"),
    ("immich", {"apiKey": "private-immich"}, "/api/server/about", {"version": "v2.5.0", "licensed": False, "versionUrl": "https://example.test/version"}, ("x-api-key", "private-immich"), "v2.5.0"),
    ("adguard", {"username": "user", "password": "private-adguard"}, "/control/status", {"version": "v0.107.0", "dns_addresses": ["127.0.0.1"], "running": True}, ("Authorization", "Basic dXNlcjpwcml2YXRlLWFkZ3VhcmQ="), "v0.107.0"),
])
def test_protected_read_only_identity(kind, credentials, path, payload, header, version):
    ambiguous_auth = kind in {"sonarr", "radarr", "lidarr", "readarr", "prowlarr", "adguard"}
    fake = FakeFactory(*([reply(b"Unauthorized", 401)] if ambiguous_auth else []), reply(payload))
    result = probe_connection(connection(kind, credentials), fake)
    assert result == ProbeResult("authenticated", version)
    base, method, actual_path, headers, body, options = fake.calls[-1]
    assert (base, method, actual_path, body) == ("https://service.test/prefix", "GET", path, None)
    assert headers[header[0]] == header[1]
    assert 0 < options["timeout"] <= 8
    assert options["max_bytes"] <= 65536
    assert all(item.closed for item in fake.instances)
    if ambiguous_auth:
        assert fake.calls[0][3] == {}


@pytest.mark.parametrize("kind,payload,credentials", [
    *[(kind, {"appName": kind.title(), "version": "6.0.1"}, {"apiKey": "wrong-key"}) for kind in ("sonarr", "radarr", "lidarr", "readarr", "prowlarr")],
    ("adguard", {"version": "0.107.0", "running": True, "dns_addresses": []}, {"username": "user", "password": "wrong-password"}),
])
def test_auth_disabled_or_local_bypass_never_claims_credential_verification(kind, payload, credentials):
    fake = FakeFactory(reply(payload))
    assert probe_connection(connection(kind, credentials), fake).state == "reachable"
    assert len(fake.calls) == 1
    assert fake.calls[0][3] == {}


@pytest.mark.parametrize("status,state,calls", [(401, "authenticated", 2), (403, "authenticated", 2), (302, "unsupported", 1), (503, "unavailable", 1)])
def test_only_an_auth_challenge_allows_credential_followup(status, state, calls):
    fake = FakeFactory(reply(None, status), reply({"appName": "Sonarr", "version": "4.0.1"}))
    assert probe_connection(connection("sonarr", {"apiKey": "private-arr"}), fake).state == state
    assert len(fake.calls) == calls


def test_music_assistant_uses_authenticated_raw_http_info_response():
    fake = FakeFactory(reply({"server_id": "mass-id", "schema_version": 29, "server_version": "2.8.0"}))
    assert probe_connection(connection("music_assistant", {"token": "private-mass"}), fake) == ProbeResult("authenticated", "2.8.0")
    _, method, path, headers, body, _ = fake.calls[0]
    assert (method, path) == ("POST", "/api")
    assert headers["Authorization"] == "Bearer private-mass"
    assert json.loads(body) == {"message_id": "larenor-probe", "command": "info", "args": {}}


@pytest.mark.parametrize("kind,payload,path,version", [
    ("frigate", b"0.16.0-abcdef", "/api/version", "0.16.0-abcdef"),
    ("jellyfin", {"ProductName": "Jellyfin Server", "Version": "10.11.0"}, "/System/Info/Public", "10.11.0"),
    ("immich", {"major": 2, "minor": 5, "patch": 0}, "/api/server/version", "2.5.0"),
    ("seerr", {"initialized": True, "applicationTitle": "Seerr", "mediaServerType": 2}, "/api/v1/settings/public", None),
])
def test_public_identity_is_only_reachable(kind, payload, path, version):
    fake = FakeFactory(reply(payload))
    assert probe_connection(connection(kind), fake) == ProbeResult("reachable", version)
    assert fake.calls[0][2] == path
    assert not any(key.lower() in {"authorization", "x-api-key", "x-emby-token"} for key in fake.calls[0][3])


def test_frigate_does_not_forward_unverified_credentials_to_public_version():
    fake = FakeFactory(reply(b"0.16.0"))
    assert probe_connection(connection("frigate", {"token": "private-frigate"}), fake).state == "reachable"
    assert "private-frigate" not in repr(fake.calls)


@pytest.mark.parametrize("status,state", [(301, "unsupported"), (302, "unsupported"), (307, "unsupported"), (400, "unsupported"), (401, "unauthorized"), (403, "unauthorized"), (404, "unsupported"), (429, "unavailable"), (500, "unavailable"), (503, "unavailable")])
def test_http_failure_classification_never_parses_or_follows_error_body(status, state):
    fake = FakeFactory(reply(b"private-body\xff", status, (("location", "https://other.test/"),)))
    assert probe_connection(connection("home_assistant", {"token": "private-ha"}), fake) == ProbeResult(state)
    assert len(fake.calls) == 1
    assert fake.instances[0].closed


@pytest.mark.parametrize("code,state", [("request_timeout", "unavailable"), ("resolution_failed", "unavailable"), ("tls_failed", "unavailable"), ("address_blocked", "unsupported"), ("invalid_response", "unsupported"), ("response_too_large", "unsupported"), ("unsupported_encoding", "unsupported")])
def test_static_transport_failure_mapping(code, state):
    fake = FakeFactory(ProbeTransportError(code))
    assert probe_connection(connection(), fake) == ProbeResult(state)
    assert fake.instances[0].closed


@pytest.mark.parametrize("body", [b"[]", b"null", b"true", b"<html>sign in</html>", b'{"version":"1.0","version":"2.0","components":[]}', b'{"version":NaN,"components":[]}', b"{" * 1000, b"\xff"])
def test_malformed_json_is_unsupported(body):
    assert probe_connection(connection(), FakeFactory(reply(body))) == ProbeResult("unsupported")


@pytest.mark.parametrize("version", ["x" * 81, "1.0\nprivate", "1.0<script>", "", None, 1, True, "private-ha", "1.0 private-ha", "☃"])
def test_version_is_bounded_and_cannot_reflect_a_credential(version):
    result = probe_connection(connection(credentials={"token": "private-ha"}), FakeFactory(reply({"version": version, "components": []})))
    assert result == ProbeResult("unsupported")
    assert "private-ha" not in repr(result)


@pytest.mark.parametrize("kind,payload", [
    ("home_assistant", {"version": "1.0"}),
    ("sonarr", {"appName": "Radarr", "version": "1.0"}),
    ("music_assistant", {"result": {"server_id": "mass-id", "schema_version": 1, "server_version": "2.0"}}),
    ("jellyfin", {"ProductName": "Other", "Version": "1.0"}),
    ("immich", {"major": True, "minor": 2, "patch": 3}),
    ("seerr", {"initialized": True}),
    ("adguard", {"version": "1.0", "running": "true", "dns_addresses": []}),
    ("frigate", b"sign in please"),
])
def test_generic_or_wrong_service_response_is_unsupported(kind, payload):
    assert probe_connection(connection(kind), FakeFactory(reply(payload))).state == "unsupported"


def test_jellyfin_setup_bypass_is_not_authenticated():
    fake = FakeFactory(reply({"ProductName": "Jellyfin Server", "Version": "10.11.0", "StartupWizardCompleted": False}))
    assert probe_connection(connection("jellyfin", {"token": "private-jelly"}), fake).state == "reachable"


def test_qbittorrent_login_and_scoped_session_version_read():
    fake = FakeFactory(reply(b"Ok.", headers=(("set-cookie", "unrelated=x; Path=/"), ("set-cookie", "SID=private-session; Path=/prefix; Secure; HttpOnly"))), reply(b"v5.1.2\n"))
    result = probe_connection(connection("qbittorrent", {"username": "user+name", "password": "private&password"}), fake)
    assert result == ProbeResult("authenticated", "v5.1.2")
    assert [(call[1], call[2]) for call in fake.calls] == [("POST", "/api/v2/auth/login"), ("GET", "/api/v2/app/version")]
    assert fake.calls[0][4] == b"username=user%2Bname&password=private%26password"
    assert fake.calls[0][3]["Referer"] == "https://service.test/prefix/"
    assert fake.calls[1][3]["Cookie"] == "SID=private-session"
    assert all(item.closed for item in fake.instances)
    assert "private" not in repr(result)


@pytest.mark.parametrize("cookie", [
    "SID=secret; Domain=evil.test; Path=/", "SID=secret; Domain=test; Path=/", "SID=secret; Path=/elsewhere",
    "SID=secret; Path=/prefix/api/v2/auth", "SID=secret; Max-Age=0; Path=/", "SID=secret; Max-Age=-1; Path=/",
    "SID=secret; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/", "SID=secret; Max-Age=no; Path=/",
    "SID=secret; Path=/; Path=/prefix", "SID=secret\r\nX-Leak: secret; Path=/", "SID=; Path=/",
    "SID=secret; Secure; Path=/", "SID=secret; Domain=service.test.; Path=/",
])
def test_unsafe_cookie_never_reaches_followup(cookie):
    fake = FakeFactory(reply(b"Ok.", headers=(("set-cookie", cookie),)))
    assert probe_connection(connection("qbittorrent", {"username": "user", "password": "secret"}, "http://service.test/prefix"), fake).state == "unsupported"
    assert len(fake.calls) == 1


def test_duplicate_session_cookie_rejected():
    fake = FakeFactory(reply(b"Ok.", headers=(("set-cookie", "SID=a; Path=/"), ("set-cookie", "SID=b; Path=/"))))
    assert probe_connection(connection("qbittorrent", {"username": "u", "password": "p"}), fake).state == "unsupported"
    assert len(fake.calls) == 1


@pytest.mark.parametrize("payload,state", [(b"Fails.", "unauthorized"), (b"<html>Ok.</html>", "unsupported"), (b"Ok.", "unsupported")])
def test_qbittorrent_login_requires_exact_success_and_session(payload, state):
    fake = FakeFactory(reply(payload))
    assert probe_connection(connection("qbittorrent", {"username": "u", "password": "p"}), fake).state == state
    assert len(fake.calls) == 1


def test_no_credentials_cannot_claim_qbittorrent_authentication():
    fake = FakeFactory(reply(b"v5.1.2"))
    assert probe_connection(connection("qbittorrent"), fake) == ProbeResult("reachable", "v5.1.2")


def test_entire_multistep_deadline_and_cleanup(monkeypatch):
    clock = [10.0]
    monkeypatch.setattr(probe.time, "monotonic", lambda: clock[0])
    fake = FakeFactory(reply(b"Ok.", headers=(("set-cookie", "SID=session-value; Path=/"),)), reply(b"v5.1.2"), clock=clock, durations=[7.0, 5.1])
    assert probe_connection(connection("qbittorrent", {"username": "u", "password": "p"}), fake) == ProbeResult("unavailable")
    assert [call[5]["timeout"] for call in fake.calls] == [8.0, 5.0]
    assert all(item.closed for item in fake.instances)


def test_expired_deadline_does_not_start_followup(monkeypatch):
    clock = [10.0]
    monkeypatch.setattr(probe.time, "monotonic", lambda: clock[0])
    fake = FakeFactory(reply(b"Ok.", headers=(("set-cookie", "SID=session-value; Path=/"),)), clock=clock, durations=[12.1])
    assert probe_connection(connection("qbittorrent", {"username": "u", "password": "p"}), fake).state == "unavailable"
    assert len(fake.calls) == 1


@pytest.mark.parametrize("kind,credentials", [("unknown", {}), ("home_assistant", {"password": "secret"}), ("adguard", {"token": "secret"}), ("qbittorrent", {"username": "user"}), ("sonarr", {"apiKey": "a", "password": "secret"})])
def test_unimplemented_api_or_credential_mode_is_explicit_without_network(kind, credentials):
    fake = FakeFactory()
    assert probe_connection(connection(kind, credentials), fake) == ProbeResult("unsupported")
    assert not fake.calls


def test_credential_header_injection_rejected_before_factory():
    fake = FakeFactory()
    assert probe_connection(connection(credentials={"token": "secret\r\nX-Test: leak"}), fake).state == "unsupported"
    assert not fake.calls


def test_cookie_repr_hides_every_source_string():
    response = reply(b"Ok.", headers=(("set-cookie", "SID=private-session; Path=/private-path; Domain=service.test; Secure; Max-Age=60"),))
    cookie = probe._session_cookie(response, "https://service.test/private-path/login")
    assert "private" not in repr(cookie)
    assert "service.test" not in repr(cookie)
    assert cookie.header("https://service.test/private-path/version") == "SID=private-session"
    with pytest.raises(probe._ProbeStop):
        cookie.header("https://other.test/private-path/version")
    with pytest.raises(probe._ProbeStop):
        cookie.header("https://service.test:444/private-path/version")
    with pytest.raises(probe._ProbeStop):
        cookie.header("http://service.test/private-path/version")


def test_cookie_expiry_is_rechecked_before_use(monkeypatch):
    now = [100.0]
    monkeypatch.setattr(probe.time, "time", lambda: now[0])
    cookie = probe._session_cookie(reply(b"Ok.", headers=(("set-cookie", "SID=private-session; Path=/; Max-Age=1"),)), "https://service.test/login")
    now[0] += 2
    with pytest.raises(probe._ProbeStop):
        cookie.header("https://service.test/version")


@pytest.mark.parametrize("headers", [(("content-type", "text/html"),), (("content-type", "application/json"), ("content-type", "text/plain"))])
def test_json_mime_confusion_rejected(headers):
    fake = FakeFactory(reply({"version": "1.0", "components": []}, headers=headers))
    assert probe_connection(connection(), fake).state == "unsupported"


def test_nonfinite_json_number_in_ignored_field_rejected():
    fake = FakeFactory(reply(b'{"version":"1.0","components":[],"other":1e999}'))
    assert probe_connection(connection(), fake).state == "unsupported"


def test_large_fake_response_is_bounded_before_parsing():
    fake = FakeFactory(reply(b" " * 65537))
    assert probe_connection(connection(), fake).state == "unsupported"


def test_factory_failure_is_static_and_has_no_partial_instance():
    def broken_factory(*_args, **_kwargs):
        raise OSError("private-address private-password")
    result = probe_connection(connection(), broken_factory)
    assert result == ProbeResult("unavailable")
    assert "private" not in repr(result)


@pytest.mark.parametrize("suffix,version", [({}, "2.5.0"), ({"prerelease": None}, "2.5.0"), ({"prerelease": 3}, "2.5.0-3")])
def test_immich_numeric_versions(suffix, version):
    fake = FakeFactory(reply({"major": 2, "minor": 5, "patch": 0, **suffix}))
    assert probe_connection(connection("immich"), fake) == ProbeResult("reachable", version)


def test_session_cookie_cannot_be_reflected_as_public_version():
    fake = FakeFactory(reply(b"Ok.", headers=(("set-cookie", "SID=v5.1.2-session; Path=/"),)), reply(b"v5.1.2-session"))
    assert probe_connection(connection("qbittorrent", {"username": "user", "password": "secret"}), fake) == ProbeResult("unsupported")


def test_encoded_basic_credential_cannot_be_reflected_as_version():
    # user:pass has no Base64 padding, and fits the otherwise safe version alphabet.
    fake = FakeFactory(reply(None, 401), reply({"version": "dXNlcjpwYXNz", "dns_addresses": [], "running": True}))
    assert probe_connection(connection("adguard", {"username": "user", "password": "pass"}), fake) == ProbeResult("unsupported")


def test_explicit_keenetic_challenge_returns_only_bounded_401_and_closes():
    response = reply(b"", 401, (("x-ndm-challenge", "challenge"),))
    fake = FakeFactory(response)
    inspector = probe._Probe(connection("keenetic"), fake)
    assert inspector.request("GET", "/auth", allow_auth_challenge=True) is response
    assert fake.instances[0].closed


@pytest.mark.parametrize("method,path,status,state", [("GET", "/auth", 403, "unauthorized"), ("GET", "/auth", 302, "unsupported"), ("POST", "/auth", 401, "unsupported"), ("GET", "/elsewhere", 401, "unsupported")])
def test_challenge_exception_is_narrow(method, path, status, state):
    fake = FakeFactory(reply(None, status))
    inspector = probe._Probe(connection("keenetic"), fake)
    with pytest.raises(probe._ProbeStop) as caught:
        inspector.request(method, path, allow_auth_challenge=True)
    assert caught.value.state == state


def test_validated_custom_cookie_name_retains_origin_and_path_scope():
    cookie = probe._session_cookie(reply(None, headers=(("set-cookie", "session_id=private-value; Path=/; Secure"),)), "https://service.test/auth", name="session_id")
    assert cookie.header("https://service.test/rci/show/version") == "session_id=private-value"
    assert "private-value" not in repr(cookie)


@pytest.mark.parametrize("name", ["", "x" * 81, "SID\r\nLeaked: x", "session=id", "session id"])
def test_untrusted_cookie_name_rejected(name):
    with pytest.raises(probe._ProbeStop):
        probe._session_cookie(reply(None), "https://service.test/auth", name=name)
