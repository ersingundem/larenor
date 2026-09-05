"""Pure preparation of the six internal components of one Larenor installation.

The supplied catalog is revalidated against its package pins without filesystem
or network access. Child plans preserve their original requested effects, which
include public web bindings and Music Assistant host networking. They are not a
private bootstrap policy or permission to install. Resources are summed requested
budgets, not measured capacity or the size of a user's media library.
"""

import hashlib
import json
import re
from typing import Annotated, Literal

from pydantic import BaseModel, Field, StrictBool, field_validator, model_validator

from ..context import ContextResponse, Identity
from .catalog import CATALOG_DIGEST, plan as child_plan
from .models import Catalog, Digest, FrozenModel, InstallPlan, Platform, ServiceId


_ORDER = ('qbittorrent', 'sonarr', 'radarr', 'jellyfin', 'seerr', 'music_assistant')
_STEPS = ('prepare_storage', 'create_container', 'start_container', 'bootstrap', 'verify_service')
_BLOCKERS = ('managed_install_unavailable', 'host_preflight_required',
             'private_bootstrap_required', 'auto_wiring_required')
_SLUG = re.compile(r'[a-z][a-z0-9-]{0,19}\Z')
_ROOT = re.compile(r'[a-z][a-z0-9_-]{0,31}\Z')
_IDENTITY = re.compile(r'[0-9a-f]{32}\Z')
_MAX_PLAN_BYTES = 65536
StepKind = Literal['prepare_storage', 'create_container', 'start_container', 'bootstrap', 'verify_service']
Blocker = Literal['managed_install_unavailable', 'host_preflight_required',
                  'private_bootstrap_required', 'auto_wiring_required']


class MediaStackPlanError(ValueError):
    """Only fixed errors leave the planner; supplied values are never echoed."""


class MediaStackSettings(FrozenModel):
    instanceName: Annotated[str, Field(min_length=1, max_length=20, pattern=r'^[a-z][a-z0-9-]{0,19}$')] = 'larenor'
    dataRootId: Annotated[str, Field(min_length=1, max_length=32, pattern=r'^[a-z][a-z0-9_-]{0,31}$')] = 'appdata'
    libraryRootId: Annotated[str, Field(min_length=1, max_length=32, pattern=r'^[a-z][a-z0-9_-]{0,31}$')] = 'library'
    musicRootId: Annotated[str, Field(min_length=1, max_length=32, pattern=r'^[a-z][a-z0-9_-]{0,31}$')] | None = None

    @field_validator('instanceName', 'dataRootId', 'libraryRootId', 'musicRootId', mode='before')
    @classmethod
    def valid_setting(cls, value, info):
        if info.field_name == 'musicRootId' and value is None:
            return value
        expression = _SLUG if info.field_name == 'instanceName' else _ROOT
        if type(value) is not str or not expression.fullmatch(value):
            raise ValueError('invalid_stack_settings')
        return value


class MediaStackStep(FrozenModel):
    kind: StepKind
    stepId: Identity


class MediaStackComponent(FrozenModel):
    serviceId: ServiceId
    installationId: Identity
    operationId: Identity
    plan: InstallPlan
    steps: tuple[MediaStackStep, ...] = Field(min_length=5, max_length=5)

    @model_validator(mode='after')
    def coherent_component(self):
        if self.serviceId != self.plan.serviceId or tuple(step.kind for step in self.steps) != _STEPS:
            raise ValueError('invalid_stack_component')
        return self


class RequestedStackResources(FrozenModel):
    memoryMiB: int = Field(ge=0, le=6 * 16384)
    cpuMillis: int = Field(ge=0, le=6 * 16000)
    pidsLimit: int = Field(ge=0, le=6 * 4096)
    minimumDiskMiB: int = Field(ge=0, le=6 * 1048576)


class MediaStackPlan(FrozenModel):
    schemaVersion: int = Field(ge=1, le=1)
    templateId: Literal['media']
    coreId: Identity
    homeId: Identity
    preparationId: Identity
    platform: Platform
    settings: MediaStackSettings
    catalogDigest: Digest
    planHash: Digest
    installAvailable: StrictBool
    bootstrapExposure: Literal['unverified']
    blockers: tuple[Blocker, ...] = Field(min_length=4, max_length=4)
    requestedResources: RequestedStackResources
    components: tuple[MediaStackComponent, ...] = Field(min_length=6, max_length=6)

    @model_validator(mode='after')
    def disabled_preparation(self):
        if self.installAvailable or self.blockers != _BLOCKERS:
            raise ValueError('managed_install_unavailable')
        if tuple(component.serviceId for component in self.components) != _ORDER:
            raise ValueError('invalid_stack_components')
        identities = [identity for component in self.components for identity in (
            component.installationId, component.operationId, *(step.stepId for step in component.steps))]
        if len(set(identities)) != len(identities):
            raise ValueError('duplicate_stack_identity')
        return self


def _canonical(value):
    result = json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode('utf-8')
    if len(result) > _MAX_PLAN_BYTES:
        raise ValueError('stack_plan_size')
    return result


def _model_wire(value):
    # model_copy/model_construct bypass validation. Detect hidden extra fields
    # before serialization can silently discard them, including nested models.
    def check(item, depth=0):
        if depth > 16:
            raise ValueError('invalid_stack_model')
        if isinstance(item, BaseModel):
            if set(item.__dict__) != set(type(item).model_fields) or item.__pydantic_extra__:
                raise ValueError('invalid_stack_model')
            for field in item.__dict__.values():
                check(field, depth + 1)
        elif type(item) is dict:
            for field in item.values():
                check(field, depth + 1)
        elif type(item) in (tuple, list):
            for field in item:
                check(field, depth + 1)
    check(value)
    return _canonical(value.model_dump(mode='json', warnings=False))


def _component_identity(kind, context, preparation, service, step=''):
    fields = ('larenor-media-stack-v1', kind, context.coreId, context.homeId, preparation, service, step)
    return hashlib.sha256('\0'.join(fields).encode('ascii')).hexdigest()[:32]


def build_media_stack_plan(catalog, settings, platform, context, preparation_id) -> MediaStackPlan:
    """Build a deterministic preparation from a supplied catalog and Core context.

    The caller owns authorization and binds preparation_id to one immutable
    request. No ID generation, host inspection or execution happens here.
    """
    try:
        if type(settings) is MediaStackSettings:
            selected = MediaStackSettings.model_validate_json(_model_wire(settings))
        elif type(settings) is dict:
            selected = MediaStackSettings.model_validate(settings)
        else:
            raise ValueError()
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise MediaStackPlanError('invalid_stack_settings') from None
    if type(platform) is not str or platform not in ('linux/amd64', 'linux/arm64'):
        raise MediaStackPlanError('unsupported_platform')
    try:
        if (type(context) is not ContextResponse or type(preparation_id) is not str
                or not _IDENTITY.fullmatch(preparation_id)):
            raise ValueError()
        context = ContextResponse.model_validate_json(_model_wire(context))
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise MediaStackPlanError('invalid_stack_identity') from None
    try:
        if type(catalog) is not Catalog:
            raise ValueError()
        trusted = Catalog.model_validate_json(_model_wire(catalog))
        if trusted.digest != CATALOG_DIGEST or {entry.manifest.serviceId for entry in trusted.entries} != set(_ORDER):
            raise ValueError()
        entries = {entry.manifest.serviceId: entry for entry in trusted.entries}
        components = []
        for service in _ORDER:
            values = {'instanceName': selected.instanceName + '-' + service.replace('_', '-'),
                      'dataRootId': selected.dataRootId}
            if service in ('qbittorrent', 'sonarr', 'radarr'):
                values['libraryRootId'] = selected.libraryRootId
            elif service == 'jellyfin':
                values['mediaRootId'] = selected.libraryRootId
            elif service == 'music_assistant':
                values['musicRootId'] = selected.musicRootId
            # child_plan independently revalidates each entry's manifest pin.
            child = child_plan(entries[service], values, platform)
            components.append(MediaStackComponent(serviceId=service,
                installationId=_component_identity('installation', context, preparation_id, service),
                operationId=_component_identity('operation', context, preparation_id, service), plan=child,
                steps=tuple(MediaStackStep(kind=kind, stepId=_component_identity('step', context, preparation_id, service, kind))
                            for kind in _STEPS)))
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise MediaStackPlanError('catalog_untrusted') from None
    requested = RequestedStackResources(**{
        field: sum(getattr(component.plan.resources, field) for component in components)
        for field in RequestedStackResources.model_fields})
    result = MediaStackPlan(schemaVersion=1, templateId='media', coreId=context.coreId, homeId=context.homeId,
        preparationId=preparation_id, platform=platform, settings=selected, catalogDigest=trusted.digest,
        planHash='0' * 64, installAvailable=False, bootstrapExposure='unverified', blockers=_BLOCKERS,
        requestedResources=requested, components=tuple(components))
    return result.model_copy(update={'planHash': hashlib.sha256(
        _canonical(result.model_dump(mode='json', exclude={'planHash'}))).hexdigest()})


def verify_media_stack_plan(value, catalog) -> MediaStackPlan:
    """Re-derive every effect and ID, without granting current Core authority.

    Persistence/IPC callers must additionally compare coreId, homeId and
    preparationId with their own authenticated context and durable record.
    """
    try:
        if type(value) is not MediaStackPlan:
            raise ValueError()
        validated = MediaStackPlan.model_validate_json(_model_wire(value))
        context = ContextResponse(schemaVersion=1, coreId=validated.coreId, homeId=validated.homeId)
        expected = build_media_stack_plan(catalog, validated.settings, validated.platform, context, validated.preparationId)
        if expected != validated:
            raise ValueError()
        return expected
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise MediaStackPlanError('stack_plan_untrusted') from None
