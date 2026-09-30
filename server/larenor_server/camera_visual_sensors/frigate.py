"""Read actual Frigate 0.17 single-camera state-classification attempts.

This consumes a trained provider model, not a client-supplied detection. Frigate
does not retain every stable 100% attempt; missing recent evidence stays unknown.
No training, camera mutation, raw image export or access-control effect is made.
"""

from datetime import datetime
import hashlib
import json
import math
import re
import shutil
import tempfile
import time
from typing import Literal

from pydantic import Field

from ..errors import ApiError, StartupError
from ..home_resources.models import FrozenModel, Identity
from ..media_archive_actions.verifier import MediaArchiveOutputVerifier, ArchiveVerificationError
from .http_models import ConfigureVisualSensorRule, SubmitVisualSensorObservation, VisualEngineCapability
from .models import (
    CameraVisualAuthority,
    Detection,
    DetectionBatch,
    EvidenceDescriptor,
    VisualSensorRule,
)

_NAME = re.compile(r"[A-Za-z0-9_]{1,80}\Z")
_FILE = re.compile(r"none-none-(\d{1,12}(?:\.\d{1,9})?)-([A-Za-z0-9_]{1,80})-(0(?:\.\d{1,8})?|1(?:\.0{1,8})?)\.webp\Z")
MAX_ATTEMPTS = 256
MAX_FRAME = 4 * 1024 * 1024


def _revision(value):
    return int(hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:13], 16) + 1


class BindFrigateVisualSensor(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: int = Field(ge=0, lt=2**63 - 1)
    cameraId: Identity
    modelName: str = Field(pattern=r"^[A-Za-z0-9_]{1,80}$")
    label: str = Field(pattern=r"^[A-Za-z0-9_]{1,80}$")
    minimumConfidenceBps: int = Field(ge=1, le=10000)
    holdForMs: int = Field(ge=0, le=60000)
    clearAfterMs: int = Field(ge=0, le=300000)
    evidenceRetentionMs: int = Field(ge=1000, le=300000)


class _FrameDecoder(MediaArchiveOutputVerifier):
    _FORMATS = "webp_pipe"

    @classmethod
    def verify(cls, raw, cancelled):
        if (not isinstance(raw, bytes) or not 16 <= len(raw) <= MAX_FRAME
                or raw[:4] != b"RIFF" or raw[8:12] != b"WEBP"):
            raise ApiError("visual_sensor_frame_invalid", 503)
        try:
            decoder = cls(shutil.which("ffmpeg"), shutil.which("ffprobe"))
            deadline = time.monotonic() + 3
            with tempfile.TemporaryFile() as frame:
                frame.write(raw); frame.flush()
                fd = frame.fileno()
                probe = json.loads(decoder._run([
                    decoder.ffprobe, "-v", "error", "-max_alloc", "16777216", *decoder._input(fd),
                    "-show_entries", "stream=codec_name,width,height", "-of", "json",
                ], fd, deadline, cancelled))
                streams = probe.get("streams")
                if (type(streams) is not list or len(streams) != 1
                        or streams[0].get("codec_name") != "webp"
                        or any(type(streams[0].get(key)) is not int for key in ("width", "height"))
                        or not 1 <= streams[0]["width"] <= 4096
                        or not 1 <= streams[0]["height"] <= 2160
                        or streams[0]["width"] * streams[0]["height"] > 8294400):
                    raise ArchiveVerificationError()
                decoder._run([decoder.ffmpeg, "-v", "error", "-nostdin", "-xerror",
                    "-max_alloc", "16777216", "-threads", "1", *decoder._input(fd),
                    "-map", "0:v:0", "-frames:v", "1", "-f", "null", "-"], fd, deadline, cancelled)
        except (ArchiveVerificationError, ValueError, TypeError, OSError, KeyError):
            raise ApiError("visual_sensor_frame_invalid", 503) from None


class FrigateVisualSensorProvider:
    def __init__(self, runtime, service, clock):
        self.runtime, self.service, self.clock = runtime, service, clock
        self.store = runtime.store
        # Source records share the authenticated encrypted camera inventory.
        with service.db.connection() as connection:
            rows = connection.execute("SELECT id FROM camera_provider_records WHERE id LIKE 'visual-source:%' LIMIT 65").fetchall()
        if len(rows) > 64:
            raise StartupError("camera_visual_sensor_storage_invalid")
        for row in rows:
            self._source(row['id'].removeprefix('visual-source:'))

    def _source(self, rule_id, connection=None):
        value = self.store.get("visual-source:" + rule_id, connection)
        if value is None:
            return None
        try:
            if (set(value) != {"settings", "sourceRevision", "modelRevision", "ruleRevision", "boundAtMs", "baseline"}
                    or any(type(value[key]) is not int or value[key] < 1
                           for key in ("sourceRevision", "modelRevision", "ruleRevision"))
                    or type(value["boundAtMs"]) is not int or value["boundAtMs"] < 0
                    or type(value["baseline"]) is not list or len(value["baseline"]) > MAX_ATTEMPTS
                    or any(not isinstance(x, str) or not _FILE.fullmatch(x) for x in value["baseline"])):
                raise ValueError
            BindFrigateVisualSensor.model_validate(value["settings"])
            return value
        except (ValueError, TypeError):
            raise StartupError("camera_visual_sensor_storage_invalid") from None

    def _context(self, actor, camera_id, cancelled):
        if cancelled():
            raise ApiError("request_cancelled", 408)
        raw, provider, authority, mapping, token, _semantic, source_guard = self.runtime._prepare(
            actor, self.runtime.core_id, self.runtime.home_id)
        if authority.role != 'admin' or camera_id not in mapping:
            raise ApiError('forbidden', 403)
        def guard():
            if cancelled():
                raise ApiError('request_cancelled', 408)
            source_guard()
        guard()
        return raw, provider, authority, mapping[camera_id], token, guard

    def _model(self, context, model_name):
        raw, provider, _authority, camera, token, guard = context
        version = self.runtime._request(provider, 'GET', '/api/version', guard, token=token, max_bytes=128).body
        if re.fullmatch(rb'0\.17\.\d+(?:[-+][A-Za-z0-9_.-]{1,80})?', version.strip()) is None:
            raise ApiError('visual_sensor_version_unsupported', 503)
        config = self.runtime._get(provider, '/api/config', guard, token)
        try:
            model = config['classification']['custom'][model_name]
            state = model['state_config']
            crop = state['cameras'][camera]['crop']
            if (type(model) is not dict or model.get('enabled') is not True
                    or model.get('object_config') is not None
                    or type(state) is not dict or set(state['cameras']) != {camera}
                    or type(crop) is not list or len(crop) != 4
                    or any(type(v) not in (float, int) or not math.isfinite(v) or not 0 <= v <= 1 for v in crop)
                    or not (crop[0] < crop[2] and crop[1] < crop[3])):
                raise ValueError
        except (KeyError, TypeError, ValueError):
            raise ApiError('visual_sensor_model_unavailable', 503) from None
        data = self.runtime._get(provider, '/api/classification/' + model_name + '/dataset', guard, token)
        try:
            metadata, categories = data['training_metadata'], data['categories']
            trained = metadata['last_training_date']
            if (metadata['has_trained'] is not True or not isinstance(trained, str)
                    or not 1 <= len(trained) <= 80 or type(categories) is not dict
                    or not 2 <= len(categories) <= 64 or any(not _NAME.fullmatch(k) for k in categories)
                    or type(metadata['last_training_image_count']) is not int
                    or metadata['last_training_image_count'] < 2):
                raise ValueError
            datetime.fromisoformat(trained)
        except (KeyError, TypeError, ValueError):
            raise ApiError('visual_sensor_model_untrained', 503) from None
        revision = _revision([raw['revision'], model, trained, metadata['last_training_image_count'], sorted(categories)])
        return revision, sorted(categories)

    def _attempts(self, context, model):
        _raw, provider, _authority, _camera, token, guard = context
        values = self.runtime._get(provider, '/api/classification/' + model + '/train', guard, token)
        if (type(values) is not list or len(values) > MAX_ATTEMPTS
                or any(not isinstance(x, str) or not _FILE.fullmatch(x) for x in values)
                or len(values) != len(set(values))):
            raise ApiError('visual_sensor_attempts_invalid', 503)
        return values

    def sources(self, actor, core_id, home_id):
        self.service._scope(core_id, home_id)
        with self.service.db.connection() as connection:
            self.service._actor(connection, actor)
            ids = [row['id'] for row in connection.execute('SELECT id FROM camera_visual_sensor_rules LIMIT 65')]
        state = self.runtime.source_state(actor)
        bindings = []
        for rule_id in ids:
            source = self._source(rule_id)
            if source is not None:
                bindings.append({'ruleId': rule_id, 'revision': source['ruleRevision'],
                    **{key: source['settings'][key] for key in ('cameraId', 'modelName', 'label',
                        'minimumConfidenceBps', 'holdForMs', 'clearAfterMs', 'evidenceRetentionMs')}})
        return {'schemaVersion': 1, 'cameraSourceRevision': state['revision'], 'cameras': state['cameras'],
                'bindings': bindings, 'trainingRequirement': 'Frigate 0.17: AVX+AVX2; configure and train in Frigate',
                'frameDecoderAvailable': bool(shutil.which('ffmpeg') and shutil.which('ffprobe'))}

    def candidates(self, actor, core_id, home_id, camera_id, *, cancelled=lambda: False):
        self.service._scope(core_id, home_id)
        with self.runtime._budget():
            context = self._context(actor, camera_id, cancelled)
            config = self.runtime._get(context[1], '/api/config', context[-1], context[4])
            try:
                custom = config['classification']['custom']
                if (type(custom) is not dict or len(custom) > 16
                        or any(not isinstance(name, str) or not _NAME.fullmatch(name) for name in custom)):
                    raise ValueError
            except (KeyError, TypeError, ValueError):
                raise ApiError('visual_sensor_model_unavailable', 503) from None
            models = []
            for name in sorted(custom):
                try:
                    revision, labels = self._model(context, name)
                except ApiError as error:
                    if error.code not in {'visual_sensor_model_unavailable', 'visual_sensor_model_untrained'}:
                        raise
                    continue
                models.append({'name': name, 'revision': revision, 'labels': labels})
            context[-1]()
            return {'schemaVersion': 1, 'cameraId': camera_id,
                    'cameraSourceRevision': context[0]['revision'], 'models': models}

    def configure(self, actor, core_id, home_id, rule_id, body, *, cancelled=lambda: False):
        self.service._scope(core_id, home_id)
        settings = BindFrigateVisualSensor.model_validate(body)
        with self.runtime._budget():
            context = self._context(actor, settings.cameraId, cancelled)
            model_revision, classes = self._model(context, settings.modelName)
            if settings.label not in classes:
                raise ApiError('invalid_request')
            baseline = self._attempts(context, settings.modelName)
            with self.service.db.connection() as connection:
                old = connection.execute('SELECT * FROM camera_visual_sensor_rules WHERE id=?', (rule_id,)).fetchone()
                current = 0 if old is None else self.service._rule(old).ruleRevision
            if current != settings.expectedRevision:
                raise ApiError('revision_conflict', 409)
            rule = VisualSensorRule(schemaVersion=1, ruleId=rule_id, ruleRevision=current + 1,
                cameraId=settings.cameraId, pipelineId=self.runtime._opaque('visual-pipeline', str(context[0]['revision'])),
                pipelineRevision=context[0]['revision'], modelId=self.runtime._opaque('visual-model', settings.modelName),
                modelRevision=model_revision, label=settings.label, minimumConfidenceBps=settings.minimumConfidenceBps,
                holdForMs=settings.holdForMs, clearAfterMs=settings.clearAfterMs,
                evidenceRetentionMs=settings.evidenceRetentionMs, enabled=True)
            context[-1]()
            fresh = self._context(actor, settings.cameraId, cancelled)
            if self._model(fresh, settings.modelName) != (model_revision, classes):
                raise ApiError('revision_conflict', 409)
            fresh[-1]()
            def persist(connection):
                self.store.put('visual-source:' + rule_id, {'settings': settings.model_dump(mode='json'),
                    'sourceRevision': context[0]['revision'], 'modelRevision': model_revision,
                    'ruleRevision': rule.ruleRevision, 'boundAtMs': int(self.clock()*1000),
                    'baseline': baseline}, connection=connection)
            # Rule, encrypted source and reducer reset commit atomically under
            # the same actor/revision guard; network reads finished beforehand.
            return self.service.configure(actor, core_id, home_id, rule_id,
                ConfigureVisualSensorRule(schemaVersion=1, expectedRevision=current, rule=rule),
                persist_source=persist)

    def refresh(self, actor, core_id, home_id, rule_id, *, cancelled=lambda: False):
        self.service._scope(core_id, home_id)
        source = self._source(rule_id)
        if source is None:
            raise ApiError('visual_sensor_source_unavailable', 503)
        settings = BindFrigateVisualSensor.model_validate(source['settings'])
        with self.service.db.connection() as connection:
            self.service._actor(connection, actor)
            row = connection.execute('SELECT * FROM camera_visual_sensor_rules WHERE id=?', (rule_id,)).fetchone()
            if row is None:
                raise ApiError('not_found', 404)
            rule = self.service._rule(row)
        if rule.ruleRevision != source['ruleRevision']:
            raise ApiError('revision_conflict', 409)
        with self.runtime._budget():
            context = self._context(actor, settings.cameraId, cancelled)
            model_revision, classes = self._model(context, settings.modelName)
            if context[0]['revision'] != source['sourceRevision'] or model_revision != source['modelRevision']:
                raise ApiError('revision_conflict', 409)
            attempts = self._attempts(context, settings.modelName)
            candidates = []
            now_ms = int(self.clock() * 1000)
            for name in attempts:
                match = _FILE.fullmatch(name)
                captured = int(float(match[1]) * 1000)
                if (name not in source['baseline'] and source['boundAtMs'] < captured <= now_ms
                        and now_ms - captured < min(rule.evidenceRetentionMs, 300000)):
                    candidates.append((captured, name, match[2], int(float(match[3]) * 10000)))
            if not candidates:
                # No new evidence is not proof of a cleared state.
                return self.service.summary(actor, core_id, home_id)
            if len({name for captured, name, _label, _confidence in candidates
                    if captured == max(x[0] for x in candidates)}) > 1:
                raise ApiError('visual_sensor_attempts_invalid', 503)
            captured, name, label, confidence = max(candidates)
            if label not in classes:
                raise ApiError('visual_sensor_attempts_invalid', 503)
            response = self.runtime._request(context[1], 'GET',
                '/clips/' + settings.modelName + '/train/' + name, context[-1], token=context[4], max_bytes=MAX_FRAME)
            _FrameDecoder.verify(response.body, cancelled)
            context[-1]()
            fresh = self._context(actor, settings.cameraId, cancelled)
            if (self._source(rule_id) != source or self._model(fresh, settings.modelName) != (model_revision, classes)
                    or name not in self._attempts(fresh, settings.modelName)):
                raise ApiError('revision_conflict', 409)
            fresh[-1]()
            capability = VisualEngineCapability(schemaVersion=1, architecture='other', avx='unknown', avx2='unknown',
                arm64=False, detectorState='ready', trainingSupported=False, inferenceSupported=True, reason='ready')
            digest = hashlib.sha256(response.body).hexdigest()
            observation = SubmitVisualSensorObservation(schemaVersion=1, expectedRuleRevision=rule.ruleRevision,
                capability=capability, batch=DetectionBatch(schemaVersion=1,
                    requestId=self.runtime._opaque('visual-attempt', rule_id + ':' + name + ':' + digest),
                    coreId=core_id, homeId=home_id, homeRevision=fresh[2].homeRevision, cameraId=rule.cameraId,
                    captureRevision=captured, pipelineId=rule.pipelineId, pipelineRevision=rule.pipelineRevision,
                    modelId=rule.modelId, modelRevision=rule.modelRevision, capturedAtMs=captured,
                    providerStatus='ready', frameStatus='complete', evidence=EvidenceDescriptor(
                        schemaVersion=1, digest=digest, byteLength=len(response.body), mediaType='image/webp',
                        expiresAtMs=captured + rule.evidenceRetentionMs),
                    detections=[Detection(schemaVersion=1, label=label, confidenceBps=confidence, count=1)]))
            authority = CameraVisualAuthority(
                schemaVersion=1, coreId=fresh[2].coreId,
                homeId=fresh[2].homeId, homeRevision=fresh[2].homeRevision,
                accountId=fresh[2].accountId,
                accountRevision=fresh[2].accountRevision,
                memberRevision=fresh[2].memberRevision,
                sessionFamilyId=fresh[2].sessionFamilyId,
                role=fresh[2].role,
                accessibleCameraIds=fresh[2].accessibleCameraIds,
                active=fresh[2].active,
                canManageVisualSensors=True,
            )
            self.service.observe(
                actor, core_id, home_id, rule_id, observation,
                authority=authority, cancelled=cancelled)
            return self.service.summary(actor, core_id, home_id)

    def summary(self, actor, core_id, home_id, *, cancelled=lambda: False):
        # GET always revalidates current provider permission/model/source before
        # presenting retained readings. No source configured stays unavailable.
        summary = self.service.summary(actor, core_id, home_id)
        with self.runtime._budget():
            for rule in summary['rules']:
                if self._source(rule.ruleId) is not None:
                    self.refresh(actor, core_id, home_id, rule.ruleId, cancelled=cancelled)
            return self.service.summary(actor, core_id, home_id)
