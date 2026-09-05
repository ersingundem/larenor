"""Offline catalog/plan contracts; no Engine, filesystem mutation or network."""

import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from larenor_server.plugins.catalog import CatalogError, catalog_bytes, load_catalog, plan, verify_plan
from larenor_server.plugins.models import CatalogManifest, InstallPlan


def entry(service):
    return next(item for item in load_catalog().entries if item.manifest.serviceId == service)


def test_packaged_catalog_has_six_pinned_non_installable_immutable_entries():
    catalog = load_catalog()
    assert {item.manifest.serviceId for item in catalog.entries} == {
        "jellyfin", "seerr", "sonarr", "radarr", "qbittorrent", "music_assistant"}
    assert len(catalog.digest) == 64
    for item in catalog.entries:
        assert not item.manifest.installable
        assert item.catalogDigest == catalog.digest
        assert len(item.manifestDigest) == 64
        assert {image.platform for image in item.manifest.images} == {"linux/amd64", "linux/arm64"}
        assert len(item.manifest.sourceRevision) == 40
        with pytest.raises(ValidationError):
            item.manifest.installable = True


@pytest.mark.parametrize("platform", ["linux/amd64", "linux/arm64"])
@pytest.mark.parametrize("service", ["jellyfin", "seerr", "sonarr", "radarr", "qbittorrent", "music_assistant"])
def test_every_platform_plan_is_deterministic_and_identifies_selected_artifact(service, platform):
    item = entry(service)
    a = plan(item, {}, platform)
    b = plan(item, {}, platform)
    assert a == b
    assert a.manifestDigest == item.manifestDigest and a.catalogDigest == item.catalogDigest
    assert a.image.platform == platform and a.image.digest.startswith("sha256:")
    assert a.image.indexDigest.startswith("sha256:")
    assert a.image.reference.endswith("@" + a.image.digest)
    assert len(a.planHash) == 64 and not a.installable
    assert a.blockers == ("worker_unverified", "host_preflight_required")
    assert a.security.privileged is False and a.security.capDrop == ("ALL",)
    assert a.security.noNewPrivileges is True


def test_settings_order_and_explicit_defaults_have_same_plan_hash():
    item = entry("jellyfin")
    default = plan(item, {}, "linux/amd64")
    settings = {setting.name: setting.value for setting in default.settings}
    assert plan(item, dict(reversed(list(settings.items()))), "linux/amd64") == default
    changed = plan(item, {"webPort": 18096}, "linux/amd64")
    assert changed.planHash != default.planHash
    assert changed.ports[0].hostPort == 18096 and changed.ports[0].containerPort == 8096


def test_qbittorrent_ports_and_environment_change_together():
    result = plan(entry("qbittorrent"), {"webPort": 18080, "torrentPort": 16881}, "linux/amd64")
    assert {(p.protocol, p.hostPort, p.containerPort) for p in result.ports} == {
        ("tcp", 18080, 18080), ("tcp", 16881, 16881), ("udp", 16881, 16881)}
    assert {v.name: v.value for v in result.environment}.items() >= {"WEBUI_PORT": "18080", "TORRENTING_PORT": "16881"}.items()


def test_music_assistant_preserves_verified_host_network_and_ptp_profile():
    result = plan(entry("music_assistant"), {"musicRootId": "music"}, "linux/arm64")
    assert result.image.indexDigest == "sha256:09c02b4ee491976efa6d698265f72571f064031bb1a2c9a1c32e104392209690"
    assert result.network.mode == "host" and result.ports == ()
    assert {(p.protocol, p.port) for p in result.network.listeners} >= {("tcp", 8095), ("tcp", 8097), ("udp", 319), ("udp", 320)}
    assert result.network.dynamicReceiverPorts is True
    assert result.security.user == "0:0" and result.security.capAdd == ("NET_BIND_SERVICE",)
    assert result.integrationRole == "internal_engine"
    assert {(m.target, m.readOnly) for m in result.mounts} >= {("/data", False), ("/media", True)}
    assert "host_network" in result.warnings and "airplay_ptp_319_320" in result.warnings


def test_distinct_app_and_library_mappings_preserve_media_boundary():
    jellyfin = plan(entry("jellyfin"), {"mediaRootId": "library"}, "linux/amd64")
    assert {m.target for m in jellyfin.mounts} == {"/config", "/cache", "/media"}
    assert next(m for m in jellyfin.mounts if m.target == "/media").readOnly
    assert {m.target for m in plan(entry("seerr"), {}, "linux/amd64").mounts} == {"/app/config"}
    for service in ("sonarr", "radarr", "qbittorrent"):
        result = plan(entry(service), {}, "linux/amd64")
        mount = next(m for m in result.mounts if m.target == "/data")
        assert mount.rootId == "library" and mount.relativePath == "" and not mount.readOnly
        assert mount.kind == "approved_library" and "writable_shared_library" in result.warnings
        assert next(m for m in result.mounts if m.target == "/config").relativePath == service + "/config"
        assert result.security.user == "1000:1000"
        assert any(t.target == "/run" and t.uid == 1000 and t.gid == 1000 and t.executable for t in result.tmpfs)
    assert next(m for m in jellyfin.mounts if m.target == "/config").rootId == "appdata"


@pytest.mark.parametrize("settings", [{"command": "x"}, {"image": "bad:latest"}, {"environment": {}},
    {"privileged": True}, {"volumes": []}, {"webPort": True}, {"webPort": "8096"}, {"webPort": 8096.0},
    {"webPort": 0}, {"webPort": 65536}, {"webPort": None}, {"instanceName": "../other"},
    {"dataRootId": "/srv/private"}, {"mediaRootId": "a/../secret"}, {"instanceName": "a;cmd"},
    {"dataRootId": "a\\b"}, {"mediaRootId": "https://host"}, {"mediaRootId": True}, {1: "bad"}])
def test_unapproved_settings_or_noncanonical_types_are_rejected(settings):
    with pytest.raises(CatalogError, match="invalid_settings"):
        plan(entry("jellyfin"), settings, "linux/amd64")


@pytest.mark.parametrize("platform", ["linux/arm/v7", "darwin/arm64", "linux/AMD64", "amd64", None, True])
def test_unsupported_platform_is_explicit(platform):
    with pytest.raises(CatalogError, match="unsupported_platform"):
        plan(entry("jellyfin"), {}, platform)


def test_port_collision_and_entry_specific_settings_are_rejected():
    with pytest.raises(CatalogError, match="invalid_settings"):
        plan(entry("qbittorrent"), {"webPort": 6881}, "linux/amd64")
    for service, settings in [("music_assistant", {"webPort": 8095}), ("seerr", {"mediaRootId": "media"})]:
        with pytest.raises(CatalogError, match="invalid_settings"):
            plan(entry(service), settings, "linux/amd64")


def test_changed_catalog_content_and_model_copy_cannot_bypass_pinning():
    raw = json.loads(catalog_bytes())
    raw["entries"][0]["version"] = "999.0"
    with pytest.raises(CatalogError):
        load_catalog(json.dumps(raw).encode())
    original = entry("jellyfin")
    forged_manifest = original.manifest.model_copy(update={"installable": True})
    forged = original.model_copy(update={"manifest": forged_manifest})
    with pytest.raises(CatalogError):
        plan(forged, {}, "linux/amd64")


@pytest.mark.parametrize("mutate", [
    lambda raw: raw.update(unknown=True),
    lambda raw: raw.update(schemaVersion=True),
    lambda raw: raw["entries"][0].update(installable=0),
    lambda raw: raw["entries"][0].update(installable=True),
    lambda raw: raw["entries"][0]["security"].update(privileged=True),
    lambda raw: raw["entries"][0]["resources"].update(memoryMiB=2048.0),
    lambda raw: raw["entries"][0]["images"][0].update(digest="sha256:bad"),
])
def test_manifest_schema_rejects_unknown_fields_types_and_privileges(mutate):
    raw = json.loads(catalog_bytes())
    mutate(raw)
    with pytest.raises(ValidationError):
        CatalogManifest.model_validate_json(json.dumps(raw))


@pytest.mark.parametrize("raw", [b'{"schemaVersion":1,"schemaVersion":1}', b'{"x":NaN}', b'[]', b'\xff', b'x' * 262145])
def test_malformed_or_oversized_catalog_is_static_error(raw):
    with pytest.raises(CatalogError):
        load_catalog(raw)


def test_reordered_json_still_has_same_canonical_catalog_digest():
    raw = json.loads(catalog_bytes())
    assert load_catalog(json.dumps(raw, sort_keys=True, indent=1).encode()).digest == load_catalog().digest


def test_calculation_does_not_read_files_or_open_network(monkeypatch):
    catalog = load_catalog()
    item = next(item for item in catalog.entries if item.manifest.serviceId == "jellyfin")
    def forbidden(*_args, **_kwargs):
        raise AssertionError("plan must be pure")
    import socket
    monkeypatch.setattr(socket, "socket", forbidden)
    monkeypatch.setattr(Path, "open", forbidden)
    monkeypatch.setattr(Path, "read_bytes", forbidden)
    result = plan(item, {}, "linux/amd64")
    assert result.serviceId == "jellyfin"
    assert verify_plan(result, catalog) == result


def test_only_music_assistant_is_the_internal_engine():
    for item in load_catalog().entries:
        expected = "internal_engine" if item.manifest.serviceId == "music_assistant" else "managed_service"
        assert item.manifest.integrationRole == plan(item, {}, "linux/amd64").integrationRole == expected


def test_managed_storage_is_instance_scoped_and_optional_music_is_read_only():
    result = plan(entry("jellyfin"), {"instanceName": "family-media", "dataRootId": "apps", "mediaRootId": "films"}, "linux/arm64")
    assert {(m.rootId, m.relativePath) for m in result.mounts if m.kind == "managed_appdata"} == {
        ("apps", "family-media/config"), ("apps", "family-media/cache")}
    assert result.mounts[-1].rootId == "films" and result.mounts[-1].readOnly
    assert all(m.target != "/media" for m in plan(entry("music_assistant"), {}, "linux/arm64").mounts)


@pytest.mark.parametrize("override", [
    {"planHash": "a" * 64}, {"catalogDigest": "a" * 64}, {"manifestDigest": "a" * 64},
    {"installable": True}, {"blockers": ()}, {"instanceName": "other"},
    {"distributionId": "linuxserver"}, {"integrationRole": "internal_engine"},
])
def test_worker_verification_rejects_forged_plan_metadata(override):
    catalog = load_catalog()
    original = plan(entry("jellyfin"), {}, "linux/amd64")
    with pytest.raises(CatalogError, match="plan_untrusted"):
        verify_plan(original.model_copy(update=override), catalog)


@pytest.mark.parametrize("field,override", [
    ("image", {"digest": "sha256:" + "a" * 64}),
    ("security", {"user": "0:0"}),
    ("security", {"capAdd": ("NET_BIND_SERVICE",)}),
    ("network", {"mode": "host"}),
    ("resources", {"memoryMiB": 8192}),
    ("health", {"path": "/private"}),
])
def test_worker_verification_rejects_forged_effects_even_with_recomputed_hash(field, override):
    import hashlib
    original = plan(entry("jellyfin"), {}, "linux/amd64")
    forged = original.model_copy(update={field: getattr(original, field).model_copy(update=override)})
    payload = forged.model_dump(mode="json", exclude={"planHash"})
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    with pytest.raises(CatalogError, match="plan_untrusted"):
        verify_plan(forged.model_copy(update={"planHash": digest}), load_catalog())


def test_duplicate_or_reordered_plan_settings_do_not_change_worker_effects():
    original = plan(entry("jellyfin"), {}, "linux/amd64")
    for settings in (original.settings + (original.settings[0],), tuple(reversed(original.settings))):
        with pytest.raises(CatalogError, match="plan_untrusted"):
            verify_plan(original.model_copy(update={"settings": settings}), load_catalog())
    decoded = InstallPlan.model_validate_json(original.model_dump_json())
    assert verify_plan(decoded, load_catalog()) == original


@pytest.mark.parametrize("mutate", [
    lambda raw: raw["entries"][0].update(integrationRole="internal_engine"),
    lambda raw: raw["entries"][0]["security"].update(noNewPrivileges=False),
    lambda raw: raw["entries"][0]["security"].update(user="0:0"),
    lambda raw: raw["entries"][0]["security"].update(capAdd=["NET_ADMIN"]),
    lambda raw: raw["entries"][0]["mounts"][0].update(relativePath=""),
    lambda raw: raw["entries"][0]["mounts"][0].update(readOnly=True),
    lambda raw: raw["entries"][2]["mounts"][1].update(relativePath="sonarr/config"),
    lambda raw: raw["entries"][2]["tmpfs"][0].update(uid=True),
    lambda raw: raw["entries"][2]["tmpfs"][0].update(uid=1),
    lambda raw: raw["entries"][0]["settings"][0].update(minimum=1),
    lambda raw: raw["entries"][0]["settings"][2].update(maximum=65536),
    lambda raw: raw["entries"][0]["settings"][0].update(default="../escape"),
    lambda raw: raw["entries"][0]["images"].__setitem__(1, raw["entries"][0]["images"][0]),
    lambda raw: raw["entries"][0]["network"].update(mode="host"),
    lambda raw: raw["entries"][5]["ports"].append(raw["entries"][0]["ports"][0]),
    lambda raw: raw["entries"].__setitem__(1, raw["entries"][0]),
])
def test_manifest_rejects_unsafe_or_inconsistent_profiles(mutate):
    raw = json.loads(catalog_bytes())
    mutate(raw)
    with pytest.raises(ValidationError):
        CatalogManifest.model_validate_json(json.dumps(raw))


@pytest.mark.parametrize("settings", [None, [], "bad", {"instanceName": "a" * 41}, {"dataRootId": "a" * 33}])
def test_settings_container_and_identifier_limits_are_strict(settings):
    with pytest.raises(CatalogError, match="invalid_settings"):
        plan(entry("jellyfin"), settings, "linux/amd64")


def test_catalog_static_errors_do_not_expose_paths_or_bad_inputs(monkeypatch):
    def unavailable(*_args, **_kwargs):
        raise PermissionError("/private/secret/path")
    monkeypatch.setattr(Path, "open", unavailable)
    with pytest.raises(CatalogError, match="^catalog_invalid$"):
        catalog_bytes()
    for raw in ("secret", b'{"x":1.0}', b'{"x":Infinity}', b'{"x":-Infinity}'):
        with pytest.raises(CatalogError, match="^catalog_invalid$"):
            load_catalog(raw)


def test_catalog_entry_and_worker_catalog_forgery_are_static_errors():
    original = entry("jellyfin")
    for forged in (None, original.model_copy(update={"catalogDigest": "a" * 64}),
                   original.model_copy(update={"manifestDigest": "a" * 64})):
        with pytest.raises(CatalogError, match="^catalog_entry_untrusted$"):
            plan(forged, {}, "linux/amd64")
    result = plan(original, {}, "linux/amd64")
    catalog = load_catalog()
    for forged in (None, catalog.model_copy(update={"digest": "a" * 64}), catalog.model_copy(update={"entries": ()})):
        with pytest.raises(CatalogError, match="^plan_untrusted$"):
            verify_plan(result, forged)


def test_packaged_catalog_read_is_bounded(monkeypatch):
    import io
    monkeypatch.setattr(Path, "open", lambda *_args, **_kwargs: io.BytesIO(b"x" * 262145))
    with pytest.raises(CatalogError, match="^catalog_invalid$"):
        catalog_bytes()
