"""Pure unified-media preparation plans; no host or Engine observation."""

import builtins
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess

import pytest
from pydantic import ValidationError

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import CATALOG_DIGEST, load_catalog, plan as child_plan
from larenor_server.plugins.stack_plan import (
    MediaStackSettings, MediaStackPlan, MediaStackPlanError,
    build_media_stack_plan, verify_media_stack_plan,
)


CONTEXT = ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32)
PREPARATION = 'c' * 32
ORDER = ('qbittorrent', 'sonarr', 'radarr', 'jellyfin', 'seerr', 'music_assistant')
STEPS = ('prepare_storage', 'create_container', 'start_container', 'bootstrap', 'verify_service')
BLOCKERS = ('managed_install_unavailable', 'host_preflight_required',
            'private_bootstrap_required', 'auto_wiring_required')


@pytest.fixture
def catalog():
    return load_catalog()


def build(catalog, settings=None, platform='linux/amd64', context=CONTEXT, preparation=PREPARATION):
    return build_media_stack_plan(catalog, {} if settings is None else settings,
                                 platform, context, preparation)


def hashed(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=False, allow_nan=False).encode()).hexdigest()


@pytest.mark.parametrize('platform', ['linux/amd64', 'linux/arm64'])
def test_unified_plan_retains_six_exact_catalog_children_and_never_enables_install(catalog, platform):
    value = build(catalog, platform=platform)
    assert value.schemaVersion == 1 and value.templateId == 'media'
    assert (value.coreId, value.homeId, value.preparationId) == (CONTEXT.coreId, CONTEXT.homeId, PREPARATION)
    assert value.catalogDigest == CATALOG_DIGEST and value.platform == platform
    assert value.installAvailable is False and value.bootstrapExposure == 'unverified'
    assert value.blockers == BLOCKERS
    assert tuple(component.serviceId for component in value.components) == ORDER
    for component in value.components:
        child = component.plan
        assert child.serviceId == component.serviceId
        assert child.image.platform == platform and child.installable is False
        assert child.instanceName == 'larenor-' + component.serviceId.replace('_', '-')
        assert tuple(step.kind for step in component.steps) == STEPS
        settings = {'instanceName': child.instanceName, 'dataRootId': 'appdata'}
        if child.serviceId in ('qbittorrent', 'sonarr', 'radarr'):
            settings['libraryRootId'] = 'library'
        elif child.serviceId == 'jellyfin':
            settings['mediaRootId'] = 'library'
        elif child.serviceId == 'music_assistant':
            settings['musicRootId'] = None
        entry = next(entry for entry in catalog.entries if entry.manifest.serviceId == child.serviceId)
        assert child == child_plan(entry, settings, platform)
    assert verify_media_stack_plan(value, catalog) == value


def test_resource_totals_are_requested_budgets_not_observed_capacity(catalog):
    value = build(catalog)
    assert value.requestedResources.model_dump() == {
        'memoryMiB': 16384, 'cpuMillis': 12000, 'pidsLimit': 3072, 'minimumDiskMiB': 49152}
    for field, total in value.requestedResources.model_dump().items():
        assert total == sum(getattr(component.plan.resources, field) for component in value.components)
    assert not {'availableMiB', 'hostNetworkAvailable', 'receiverStatus', 'portAvailability'} & set(value.model_dump())


def test_shared_library_paths_preserve_readonly_jellyfin_and_optional_music(catalog):
    value = build(catalog, {'instanceName': 'living-room', 'dataRootId': 'internal',
                            'libraryRootId': 'movies', 'musicRootId': 'songs'})
    for component in value.components:
        child = component.plan
        managed = [mount for mount in child.mounts if mount.kind == 'managed_appdata']
        assert all(mount.rootId == 'internal' and mount.relativePath.startswith(child.instanceName + '/')
                   for mount in managed)
        if child.serviceId in ('qbittorrent', 'sonarr', 'radarr'):
            shared = next(mount for mount in child.mounts if mount.target == '/data')
            assert (shared.rootId, shared.relativePath, shared.readOnly) == ('movies', '', False)
        elif child.serviceId == 'jellyfin':
            shared = next(mount for mount in child.mounts if mount.target == '/media')
            assert (shared.rootId, shared.relativePath, shared.readOnly) == ('movies', '', True)
        elif child.serviceId == 'music_assistant':
            shared = next(mount for mount in child.mounts if mount.target == '/media')
            assert (shared.rootId, shared.relativePath, shared.readOnly) == ('songs', '', True)


def test_unverified_bootstrap_exposure_is_explicit_despite_original_port_profiles(catalog):
    value = build(catalog)
    assert all(port.hostIp == '0.0.0.0' for child in value.components for port in child.plan.ports)
    music = value.components[-1].plan
    assert music.network.mode == 'host' and music.network.dynamicReceiverPorts is True
    assert music.integrationRole == 'internal_engine'
    assert music.security.user == '0:0' and music.security.capAdd == ('NET_BIND_SERVICE',)
    assert value.bootstrapExposure == 'unverified' and 'private_bootstrap_required' in value.blockers


def test_settings_defaults_order_and_catalog_entry_order_are_canonical(catalog):
    expected = build(catalog)
    defaults = MediaStackSettings()
    assert defaults.model_dump() == {'instanceName': 'larenor', 'dataRootId': 'appdata',
                                      'libraryRootId': 'library', 'musicRootId': None}
    explicit = dict(reversed(list(defaults.model_dump().items())))
    assert build(catalog, explicit) == expected == build(catalog, defaults)
    assert build(catalog.model_copy(update={'entries': tuple(reversed(catalog.entries))})) == expected
    assert expected.planHash == hashed(expected.model_dump(mode='json', exclude={'planHash'}))
    assert MediaStackPlan.model_validate_json(expected.model_dump_json()) == expected


def test_nested_plan_is_immutable_and_detached_from_input_settings(catalog):
    settings = {'instanceName': 'house'}
    value = build(catalog, settings)
    settings['instanceName'] = 'other'
    assert value.settings.instanceName == 'house'
    for model, field, replacement in [(value, 'installAvailable', True), (value.settings, 'instanceName', 'other'),
                                      (value.components[0], 'operationId', 'd' * 32),
                                      (value.components[0].steps[0], 'kind', 'bootstrap'),
                                      (value.requestedResources, 'memoryMiB', 1)]:
        with pytest.raises(ValidationError):
            setattr(model, field, replacement)
    wire = value.model_dump(mode='json')
    wire['components'][0]['plan']['mounts'].clear()
    assert value.components[0].plan.mounts


def identifiers(value):
    return tuple(identity for component in value.components for identity in (
        component.installationId, component.operationId, *(step.stepId for step in component.steps)))


def test_domain_separated_component_and_step_ids_are_stable_and_distinct(catalog):
    value = build(catalog)
    ids = identifiers(value)
    assert len(ids) == len(set(ids)) == 42
    assert all(len(identity) == 32 and set(identity) <= set('0123456789abcdef') for identity in ids)
    assert ids == identifiers(build(catalog))
    # Identity belongs to context/preparation/component, not mutable settings.
    assert ids == identifiers(build(catalog, {'instanceName': 'other'}, 'linux/arm64'))
    for context, preparation in [(CONTEXT.model_copy(update={'coreId': 'd' * 32}), PREPARATION),
                                 (CONTEXT.model_copy(update={'homeId': 'd' * 32}), PREPARATION),
                                 (CONTEXT, 'd' * 32)]:
        changed = build(catalog, context=context, preparation=preparation)
        assert not set(ids).intersection(identifiers(changed))
        assert changed.planHash != value.planHash


def test_twenty_character_prefix_still_fits_each_child_slug(catalog):
    value = build(catalog, {'instanceName': 'a' * 20})
    assert max(len(component.plan.instanceName) for component in value.components) == 36


@pytest.mark.parametrize('settings', [None, [], 'private-secret', True, {'instanceName': ''},
    {'instanceName': 'a' * 21}, {'instanceName': 'Upper'}, {'instanceName': '../escape'},
    {'instanceName': 'a\n'}, {'instanceName': 1}, {'dataRootId': None}, {'dataRootId': '/srv/private'},
    {'dataRootId': 'root\n'}, {'libraryRootId': 'a' * 33}, {'libraryRootId': True},
    {'musicRootId': 1}, {'musicRootId': 'https://private'}, {'musicRootId': ''},
    {'webPort': 18096}, {'image': 'private-secret'}, {'mounts': []}, {'capAdd': []},
    {'environment': {}}, {'platform': 'linux/amd64'}, {1: 'private-secret'}])
def test_unknown_settings_types_and_effect_overrides_are_rejected(catalog, settings):
    with pytest.raises(MediaStackPlanError, match='^invalid_stack_settings$'):
        build_media_stack_plan(catalog, settings, 'linux/amd64', CONTEXT, PREPARATION)


@pytest.mark.parametrize('platform', [None, True, 1, 'linux/arm/v7', 'darwin/arm64', 'linux/AMD64', 'linux/amd64\n'])
def test_unsupported_platform_is_explicit(catalog, platform):
    with pytest.raises(MediaStackPlanError, match='^unsupported_platform$'):
        build(catalog, platform=platform)


@pytest.mark.parametrize('identity', [None, True, 1, '', 'A' * 32, 'a' * 31, 'a' * 33, 'a' * 32 + '\n'])
def test_invalid_preparation_identity_is_static(catalog, identity):
    with pytest.raises(MediaStackPlanError, match='^invalid_stack_identity$'):
        build(catalog, preparation=identity)


@pytest.mark.parametrize('context', [None, {}, CONTEXT.model_dump(),
    CONTEXT.model_copy(update={'schemaVersion': True}), CONTEXT.model_copy(update={'coreId': 'secret'}),
    CONTEXT.model_copy(update={'homeId': 1})])
def test_context_must_be_an_independently_valid_typed_value(catalog, context):
    with pytest.raises(MediaStackPlanError, match='^invalid_stack_identity$'):
        build(catalog, context=context)


def test_forged_settings_model_is_revalidated(catalog):
    with pytest.raises(MediaStackPlanError, match='^invalid_stack_settings$'):
        build(catalog, MediaStackSettings().model_copy(update={'instanceName': 'private\nsecret'}))


@pytest.mark.parametrize('kind', ['wrong_type', 'digest', 'missing', 'duplicate', 'manifest', 'entry_digest'])
def test_supplied_catalog_is_pinned_without_reading_another_copy(catalog, kind):
    if kind == 'wrong_type':
        forged = catalog.model_dump()
    elif kind == 'digest':
        forged = catalog.model_copy(update={'digest': 'f' * 64})
    elif kind == 'missing':
        forged = catalog.model_copy(update={'entries': catalog.entries[:-1]})
    elif kind == 'duplicate':
        forged = catalog.model_copy(update={'entries': (catalog.entries[0],) * 6})
    else:
        first = catalog.entries[0]
        change = {'manifest': first.manifest.model_copy(update={'tag': 'untrusted'})} if kind == 'manifest' else {'manifestDigest': 'f' * 64}
        forged = catalog.model_copy(update={'entries': (first.model_copy(update=change), *catalog.entries[1:])})
    with pytest.raises(MediaStackPlanError, match='^catalog_untrusted$'):
        build(forged)


@pytest.mark.parametrize('mutate', [
    lambda v: v.update(schemaVersion=True),
    lambda v: v.update(schemaVersion=1.0),
    lambda v: v.update(templateId='other'),
    lambda v: v.update(installAvailable=True),
    lambda v: v.update(installAvailable=0),
    lambda v: v.update(bootstrapExposure='private'),
    lambda v: v['blockers'].remove('private_bootstrap_required'),
    lambda v: v.update(hostNetworkAvailable=True),
    lambda v: v['requestedResources'].update(memoryMiB=1024),
    lambda v: v['components'].reverse(),
    lambda v: v['components'].pop(),
    lambda v: v['components'][0].update(installationId='d' * 32),
    lambda v: v['components'][0].update(operationId='d' * 32),
    lambda v: v['components'][0]['steps'][0].update(stepId='d' * 32),
    lambda v: v['components'][0]['steps'].reverse(),
    lambda v: v['components'][0]['plan']['ports'][0].update(hostPort=18080),
    lambda v: v['components'][0]['plan']['image'].update(digest='sha256:' + 'f' * 64),
    lambda v: v['components'][0]['plan']['mounts'][0].update(rootId='other'),
    lambda v: v['components'][0]['plan']['security'].update(privileged=True),
])
def test_rehashed_forged_copy_cannot_authorize_changed_effects(catalog, mutate):
    original = build(catalog)
    wire = original.model_dump(mode='json')
    mutate(wire)
    wire['planHash'] = hashed({key: value for key, value in wire.items() if key != 'planHash'})
    forged = original.model_copy(update=wire)
    with pytest.raises(MediaStackPlanError, match='^stack_plan_untrusted$'):
        verify_media_stack_plan(forged, catalog)


def test_verify_rejects_arbitrary_dict_and_binds_the_exact_requested_settings(catalog):
    value = build(catalog)
    with pytest.raises(MediaStackPlanError, match='^stack_plan_untrusted$'):
        verify_media_stack_plan(value.model_dump(), catalog)
    with pytest.raises(MediaStackPlanError, match='^stack_plan_untrusted$'):
        verify_media_stack_plan(value.model_copy(update={'planHash': 'f' * 64}), catalog)
    forged = value.model_copy(update={'settings': value.settings.model_copy(update={'libraryRootId': 'other'})})
    with pytest.raises(MediaStackPlanError, match='^stack_plan_untrusted$'):
        verify_media_stack_plan(forged, catalog)


def test_planning_and_verifying_have_no_host_reads_randomness_or_network(catalog, monkeypatch):
    def forbidden(*args, **kwargs):
        pytest.fail('pure planner attempted I/O or randomness')
    for target, name in [(builtins, 'open'), (Path, 'open'), (Path, 'stat'), (os, 'stat'),
                         (os, 'urandom'), (socket, 'socket'), (subprocess, 'Popen')]:
        monkeypatch.setattr(target, name, forbidden)
    value = build(catalog)
    assert verify_media_stack_plan(value, catalog) == value
