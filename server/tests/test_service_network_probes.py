"""Synthetic Keenetic/Proxmox/ESPHome replies; never contact a home service."""

import json
from urllib.parse import parse_qs

import pytest

from larenor_server.services import network_probes, probe
from larenor_server.services.probe import ProbeResult, probe_connection
from larenor_server.services.transport import ProbeTransportError
from test_service_probes import FakeFactory, connection, reply


KN_CREDENTIALS = {"username": "admin", "password": "private-kn"}
KN_VERSION = {"title": "5.0.4", "model": "Giga (KN-1011)", "hw_id": "KN-1011"}
KN_DIGEST = "aa274028fb92ae13c401eff07cb63f918ed0e462ba9fd1b7cd53e53092d6625c"
PVE_TOKEN = "probe@pve!monitor=11111111-2222-3333-4444-555555555555"
PVE_CREDENTIALS = {"username": "probe@pve", "password": "private-pve&plus+"}
PVE_VERSION = {"data": {"version": "9.0.3", "release": "9.0", "repoid": "deadbeef12345678"}}
PVE_TICKET = "PVE:probe@pve:65ABCDEF::c3ludGhldGljLXNpZ25hdHVyZQ=="
PVE_LOGIN = {"data": {"username": "probe@pve", "ticket": PVE_TICKET,
                       "CSRFPreventionToken": "65ABCDEF:synthetic-csrf"}}


def challenge(cookie="SYNTHETICCOOKIE", value="preauth123", *, attributes="; Path=/prefix; HttpOnly", extra=()):
    fields = (("X-NDM-Realm", "Keenetic"), ("X-NDM-Challenge", "SYNTHETICCHALLENGE"),
              ("WWW-Authenticate", 'x-ndw2-interactive realm="Keenetic" challenge="SYNTHETICCHALLENGE" '
               f'session_id="{value}" session_cookie="{cookie}"'),
              ("Set-Cookie", f"{cookie}={value}{attributes}"))
    return reply(b"", 401, fields + extra)


def test_keenetic_challenge_hash_and_rotated_cookie_are_bound_to_read_only_routes():
    fake = FakeFactory(challenge(), reply(b"", headers=(("Set-Cookie", "SYNTHETICCOOKIE=authenticated456; Path=/prefix"),)), reply(KN_VERSION))
    assert probe_connection(connection("keenetic", KN_CREDENTIALS), fake) == ProbeResult("authenticated", "5.0.4")
    assert [(c[1], c[2]) for c in fake.calls] == [("GET", "/auth"), ("POST", "/auth"), ("GET", "/rci/show/version")]
    assert fake.calls[0][3] == {}
    assert fake.calls[1][3]["Cookie"] == "SYNTHETICCOOKIE=preauth123"
    assert fake.calls[1][3]["Content-Type"] == "application/json"
    assert json.loads(fake.calls[1][4]) == {"login": "admin", "password": KN_DIGEST}
    assert b"private-kn" not in fake.calls[1][4]
    assert fake.calls[2][3]["Cookie"] == "SYNTHETICCOOKIE=authenticated456"
    assert all(item.closed for item in fake.instances)
    assert all(c[0] == "https://service.test/prefix" and c[5]["max_bytes"] == 65536 for c in fake.calls)


def test_keenetic_retains_challenge_cookie_when_login_does_not_rotate_it():
    fake = FakeFactory(challenge(), reply(b""), reply(KN_VERSION))
    assert probe_connection(connection("keenetic", KN_CREDENTIALS), fake).state == "authenticated"
    assert fake.calls[-1][3]["Cookie"] == "SYNTHETICCOOKIE=preauth123"


def test_keenetic_legacy_fixed_session_cookie_and_release_shape():
    fake = FakeFactory(reply(b"", 401, (("X-NDM-Realm", "Keenetic"), ("X-NDM-Challenge", "SYNTHETICCHALLENGE"))),
                       reply(b"", headers=(("Set-Cookie", "session_id=legacy123; Path=/prefix"),)),
                       reply({"release": "2.12.A.1.0-1", "model": "4G (KN-1210)", "manufacturer": "Keenetic Ltd."}))
    assert probe_connection(connection("keenetic", KN_CREDENTIALS), fake) == ProbeResult("authenticated", "2.12.A.1.0-1")
    assert "Cookie" not in fake.calls[1][3]
    assert fake.calls[2][3]["Cookie"] == "session_id=legacy123"


@pytest.mark.parametrize("credentials", [{}, KN_CREDENTIALS])
def test_keenetic_open_auth_only_proves_reachable_and_forwards_no_secrets(credentials):
    fake = FakeFactory(reply(b""), reply(KN_VERSION))
    assert probe_connection(connection("keenetic", credentials), fake) == ProbeResult("reachable", "5.0.4")
    assert all(c[1] == "GET" and c[3] == {} and c[4] is None for c in fake.calls)


def test_keenetic_open_session_cookie_is_scoped_and_never_claims_authentication():
    fake = FakeFactory(reply(b"", headers=(("Set-Cookie", "open_session=synthetic-open; Path=/prefix; HttpOnly"),)), reply(KN_VERSION))
    result = probe_connection(connection("keenetic", KN_CREDENTIALS), fake)
    assert result == ProbeResult("reachable", "5.0.4")
    assert fake.calls[1][3] == {"Cookie": "open_session=synthetic-open"}
    assert all(call[1] == "GET" and call[4] is None for call in fake.calls)


@pytest.mark.parametrize("cookies", [
    (("Set-Cookie", "open_session=synthetic-open; Domain=other.test; Path=/"),),
    (("Set-Cookie", "open_session=one; Path=/"), ("Set-Cookie", "open_session=two; Path=/")),
    tuple(("Set-Cookie", f"session{i}=value; Path=/") for i in range(17)),
])
def test_keenetic_unsafe_or_ambiguous_open_session_never_reaches_rci(cookies):
    fake = FakeFactory(reply(b"", headers=cookies), reply(KN_VERSION))
    assert probe_connection(connection("keenetic"), fake) == ProbeResult("unsupported")
    assert len(fake.calls) == 1


def test_keenetic_open_session_value_cannot_be_reflected_as_version():
    fake = FakeFactory(reply(b"", headers=(("Set-Cookie", "open_session=5.0.4; Path=/prefix"),)), reply(KN_VERSION))
    assert probe_connection(connection("keenetic"), fake) == ProbeResult("unsupported")


def test_keenetic_missing_credentials_reports_auth_challenge_without_login():
    fake = FakeFactory(challenge())
    assert probe_connection(connection("keenetic"), fake) == ProbeResult("unauthorized")
    assert len(fake.calls) == 1


@pytest.mark.parametrize("payload", [{"model": "Giga", "hw_id": "KN-1011"},
                                     {"title": "5.0.4", "model": "Giga"},
                                     {"title": "5.0.4", "model": True, "hw_id": "KN-1011"}])
def test_keenetic_requires_version_and_product_identity(payload):
    assert probe_connection(connection("keenetic"), FakeFactory(reply(b""), reply(payload))) == ProbeResult("unsupported")


@pytest.mark.parametrize("name,value", [("realm", "Other"), ("challenge", "OTHER"),
                                       ("session_id", "other-session")])
def test_keenetic_declared_challenge_and_session_must_agree(name, value):
    original = challenge()
    headers = tuple((key, item.replace(f'{name}="' + {"realm": "Keenetic", "challenge": "SYNTHETICCHALLENGE", "session_id": "preauth123"}[name] + '"',
                                      f'{name}="{value}"') if key == "WWW-Authenticate" else item)
                    for key, item in original.headers)
    fake = FakeFactory(reply(b"", 401, headers))
    assert probe_connection(connection("keenetic", KN_CREDENTIALS), fake) == ProbeResult("unsupported")
    assert len(fake.calls) == 1


@pytest.mark.parametrize("headers", [
    (), (("X-NDM-Realm", "Keenetic"),),
    (("X-NDM-Realm", "Keenetic"), ("X-NDM-Challenge", "one"), ("x-ndm-challenge", "two")),
    (("X-NDM-Realm", "Keenetic"), ("X-NDM-Challenge", "bad\r\nheader")),
    (("X-NDM-Realm", "Keenetic"), ("X-NDM-Challenge", "x" * 4097)),
    (("X-NDM-Realm", "Keenetic"), ("X-NDM-Challenge", "one"), ("WWW-Authenticate", 'Basic realm="Keenetic"')),
])
def test_keenetic_malformed_or_other_auth_protocol_never_sends_login(headers):
    fake = FakeFactory(reply(b"", 401, headers))
    assert probe_connection(connection("keenetic", KN_CREDENTIALS), fake) == ProbeResult("unsupported")
    assert len(fake.calls) == 1


@pytest.mark.parametrize("attributes", ["; Domain=other.test; Path=/", "; Path=/other", "; Path=/prefix; Max-Age=0", "; Path=/prefix; Path=/", "; Path=/prefix; Expires=Thu, 01 Jan 1970 00:00:00 GMT"])
def test_keenetic_bad_cookie_scope_or_expiry_prevents_login(attributes):
    fake = FakeFactory(challenge(attributes=attributes))
    assert probe_connection(connection("keenetic", KN_CREDENTIALS), fake).state == "unsupported"
    assert len(fake.calls) == 1


def test_keenetic_secure_cookie_is_not_sent_over_http():
    fake = FakeFactory(challenge(attributes="; Path=/prefix; Secure"))
    assert probe_connection(connection("keenetic", KN_CREDENTIALS, "http://service.test/prefix"), fake).state == "unsupported"
    assert len(fake.calls) == 1


@pytest.mark.parametrize("bad", [challenge(extra=(("Set-Cookie", "SYNTHETICCOOKIE=other; Path=/prefix"),)),
                                  challenge(cookie="bad/name"), challenge(value="bad,value")])
def test_keenetic_ambiguous_or_unsafe_cookie_never_reaches_login(bad):
    fake = FakeFactory(bad)
    assert probe_connection(connection("keenetic", KN_CREDENTIALS), fake).state == "unsupported"
    assert len(fake.calls) == 1


@pytest.mark.parametrize("response,state", [(reply(b"", 401), "unauthorized"), (reply(b"", 403), "unauthorized"),
                                            (reply(b"", 302, (("Location", "https://other.test"),)), "unsupported"),
                                            (reply(b"", 500), "unavailable")])
def test_keenetic_login_failure_never_queries_device(response, state):
    fake = FakeFactory(challenge(), response)
    assert probe_connection(connection("keenetic", KN_CREDENTIALS), fake) == ProbeResult(state)
    assert len(fake.calls) == 2


@pytest.mark.parametrize("version", ["preauth123", "authenticated456", KN_DIGEST, "private-kn"])
def test_keenetic_ephemeral_cookie_and_digest_cannot_become_version(version):
    fake = FakeFactory(challenge(), reply(b"", headers=(("Set-Cookie", "SYNTHETICCOOKIE=authenticated456; Path=/prefix"),)),
                       reply({**KN_VERSION, "title": version}))
    assert probe_connection(connection("keenetic", KN_CREDENTIALS), fake) == ProbeResult("unsupported")


def test_proxmox_full_api_token_uses_protected_version_only():
    fake = FakeFactory(reply(b"", 401), reply(PVE_VERSION))
    assert probe_connection(connection("proxmox", {"token": PVE_TOKEN}), fake) == ProbeResult("authenticated", "9.0.3")
    assert [(c[1], c[2]) for c in fake.calls] == [("GET", "/api2/json/version")] * 2
    assert fake.calls[0][3] == {}
    assert fake.calls[1][3] == {"Authorization": "PVEAPIToken=" + PVE_TOKEN}


def test_proxmox_ticket_login_encodes_password_and_reads_without_csrf_write():
    fake = FakeFactory(reply(b"", 401), reply(PVE_LOGIN), reply(PVE_VERSION))
    assert probe_connection(connection("proxmox", PVE_CREDENTIALS), fake) == ProbeResult("authenticated", "9.0.3")
    assert [(c[1], c[2]) for c in fake.calls] == [("GET", "/api2/json/version"), ("POST", "/api2/json/access/ticket"), ("GET", "/api2/json/version")]
    assert parse_qs(fake.calls[1][4].decode()) == {k: [v] for k, v in PVE_CREDENTIALS.items()}
    assert fake.calls[1][3] == {"Content-Type": "application/x-www-form-urlencoded"}
    assert fake.calls[2][3] == {"Cookie": "PVEAuthCookie=" + PVE_TICKET}
    assert all(item.closed for item in fake.instances)


@pytest.mark.parametrize("credentials", [{}, {"token": PVE_TOKEN}, PVE_CREDENTIALS])
def test_proxmox_public_bypass_is_not_authenticated(credentials):
    fake = FakeFactory(reply(PVE_VERSION))
    assert probe_connection(connection("proxmox", credentials), fake) == ProbeResult("reachable", "9.0.3")
    assert len(fake.calls) == 1 and fake.calls[0][3] == {}


def test_proxmox_no_credentials_on_protected_version_stops_after_challenge():
    fake = FakeFactory(reply(b"", 401))
    assert probe_connection(connection("proxmox"), fake) == ProbeResult("unauthorized")
    assert len(fake.calls) == 1


@pytest.mark.parametrize("response,state", [(reply(b"", 401), "unauthorized"), (reply(b"", 403), "unauthorized"),
                                            (reply(b"", 302), "unsupported"), (reply(b"", 500), "unavailable")])
def test_proxmox_ticket_failure_stops_before_version_retry(response, state):
    fake = FakeFactory(reply(b"", 401), response)
    assert probe_connection(connection("proxmox", PVE_CREDENTIALS), fake) == ProbeResult(state)
    assert len(fake.calls) == 2


@pytest.mark.parametrize("data,state", [
    ({**PVE_LOGIN["data"], "NeedTFA": 1}, "unauthorized"),
    ({**PVE_LOGIN["data"], "ticket": "PVE:!tfa!challenge"}, "unauthorized"),
    ({**PVE_LOGIN["data"], "ticket": "PVE:probe@pve:bad; injected=yes"}, "unsupported"),
    ({**PVE_LOGIN["data"], "ticket": "not-a-ticket"}, "unsupported"),
    ({**PVE_LOGIN["data"], "username": "another@pve"}, "unsupported"),
    ({**PVE_LOGIN["data"], "CSRFPreventionToken": "csrf\r\nprivate"}, "unsupported"),
    ({"username": "probe@pve", "ticket": PVE_TICKET}, "unsupported"),
])
def test_proxmox_invalid_or_partial_ticket_never_becomes_a_cookie(data, state):
    fake = FakeFactory(reply(b"", 401), reply({"data": data}))
    assert probe_connection(connection("proxmox", PVE_CREDENTIALS), fake) == ProbeResult(state)
    assert len(fake.calls) == 2


@pytest.mark.parametrize("payload", [{"data": {"version": "9.0.3"}}, {"data": {**PVE_VERSION["data"], "repoid": "not-hex"}},
                                     {"data": []}, {"version": "9.0.3"}, {"data": {**PVE_VERSION["data"], "release": 9}}])
def test_proxmox_requires_version_release_and_repository_identity(payload):
    assert probe_connection(connection("proxmox"), FakeFactory(reply(payload))) == ProbeResult("unsupported")


def test_proxmox_secret_token_component_cannot_become_public_version():
    fake = FakeFactory(reply(b"", 401), reply({"data": {**PVE_VERSION["data"], "version": PVE_TOKEN.split("=", 1)[1]}}))
    assert probe_connection(connection("proxmox", {"token": PVE_TOKEN}), fake) == ProbeResult("unsupported")


def test_proxmox_issued_csrf_cannot_become_public_version():
    fake = FakeFactory(reply(b"", 401), reply(PVE_LOGIN),
                       reply({"data": {**PVE_VERSION["data"], "version": PVE_LOGIN["data"]["CSRFPreventionToken"]}}))
    assert probe_connection(connection("proxmox", PVE_CREDENTIALS), fake) == ProbeResult("unsupported")


@pytest.mark.parametrize("kind,credentials", [
    ("keenetic", {"token": "not-supported"}), ("keenetic", {"username": "admin"}),
    ("keenetic", {**KN_CREDENTIALS, "apiKey": "extra"}),
    ("proxmox", {"token": "missing-token-id"}), ("proxmox", {"token": "PVEAPIToken=" + PVE_TOKEN}),
    ("proxmox", {"token": PVE_TOKEN + "; bad=yes"}), ("proxmox", {"username": "probe", "password": "private"}),
    ("proxmox", {**PVE_CREDENTIALS, "token": PVE_TOKEN}), ("proxmox", {"apiKey": PVE_TOKEN}),
])
def test_unsupported_credential_modes_never_send_partial_auth(kind, credentials):
    fake = FakeFactory()
    assert probe_connection(connection(kind, credentials), fake) == ProbeResult("unsupported")
    assert fake.calls == []


@pytest.mark.parametrize("credentials", [{}, {"token": "stored-but-unverified"}, {"username": "user", "password": "stored-secret"}])
def test_esphome_public_version_never_forwards_or_claims_auth(credentials):
    fake = FakeFactory(reply({"version": "2026.8.2"}, headers=(("Content-Type", "application/json"),)))
    assert probe_connection(connection("esphome", credentials), fake) == ProbeResult("reachable", "2026.8.2")
    assert len(fake.calls) == 1 and fake.calls[0][1:5] == ("GET", "/version", {}, None)


@pytest.mark.parametrize("response,state", [(reply(b"<!doctype html>login"), "unsupported"),
                                            (reply({"version": True}), "unsupported"),
                                            (reply({"version": "2026.8.2"}, headers=(("Content-Type", "text/html"),)), "unsupported"),
                                            (reply(b"", 401), "unauthorized"), (reply(b"", 302), "unsupported")])
def test_esphome_unverified_protocol_or_auth_does_not_attempt_login(response, state):
    fake = FakeFactory(response)
    assert probe_connection(connection("esphome", {"password": "private"}), fake) == ProbeResult(state)
    assert len(fake.calls) == 1


def test_keenetic_full_exchange_shares_deadline_and_closes_every_transport(monkeypatch):
    clock = [10.0]
    monkeypatch.setattr(probe.time, "monotonic", lambda: clock[0])
    fake = FakeFactory(challenge(), reply(b""), reply(KN_VERSION), clock=clock, durations=(5, 5, 3))
    assert probe_connection(connection("keenetic", KN_CREDENTIALS), fake) == ProbeResult("unavailable")
    assert [c[5]["timeout"] for c in fake.calls] == [8, 7, 2]
    assert all(item.closed for item in fake.instances)


@pytest.mark.parametrize("kind", ["keenetic", "proxmox", "esphome"])
def test_network_transport_failure_is_static_and_closed(kind):
    fake = FakeFactory(ProbeTransportError("tls_failed"))
    assert probe_connection(connection(kind), fake) == ProbeResult("unavailable")
    assert len(fake.calls) == 1 and fake.instances[0].closed


def test_direct_network_dispatch_rejects_other_service_families():
    with pytest.raises(probe._ProbeStop, match="unsupported"):
        network_probes.network_probe(probe._Probe(connection("home_assistant"), FakeFactory()))
