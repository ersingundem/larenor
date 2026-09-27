import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/camera_visual_sensor_models.dart';

final class CameraVisualSensorApi implements CameraVisualSensorGateway {
  CameraVisualSensorApi(
    this._api,
    this._session, {
    required bool Function() isCurrent,
  }) : _current = isCurrent;

  final LarenorServerApi _api;
  final ServerSession _session;
  final bool Function() _current;
  bool _retired = false;
  ServerContext get _context => _session.context!;

  void _check() {
    if (_retired ||
        _session.context == null ||
        !_session.user.canAdminister ||
        !_current()) {
      _retired = true;
      throw const LarenorServerException('cancelled');
    }
  }

  @override
  Future<CameraVisualSensorSummary> load() async {
    _check();
    final raw = await _api.request(
      'GET',
      '/camera-visual-sensors/${_context.coreId}/${_context.homeId}/summary',
      token: _session.accessToken,
    );
    _check();
    final body = serverObject(raw);
    final version = body['schemaVersion'];
    if (body.length != 4 || (version != 1 && version != 2)) {
      throw const LarenorServerException('invalid_response');
    }
    final scope = ServerContext.fromJson(serverObject(body['scope']));
    if (scope != _context) {
      throw const LarenorServerException('invalid_response');
    }
    final capability = _capability(body['capability']);
    final rawRules = body['rules'];
    if (rawRules is! List || rawRules.length > 64) {
      throw const LarenorServerException('invalid_response');
    }
    final sensors = rawRules
        .map((value) => _sensor(value, version: version! as int))
        .toList(growable: false);
    if (sensors.map((value) => value.ruleId).toSet().length != sensors.length) {
      throw const LarenorServerException('invalid_response');
    }
    return CameraVisualSensorSummary(
      coreId: scope.coreId,
      homeId: scope.homeId,
      capability: capability,
      sensors: List.unmodifiable(sensors),
    );
  }

  VisualEngineCapability _capability(Object? raw) {
    final value = serverObject(raw);
    if (value.length != 9 ||
        value['schemaVersion'] != 1 ||
        value['trainingSupported'] is! bool ||
        value['inferenceSupported'] is! bool) {
      throw const LarenorServerException('invalid_response');
    }
    final architecture = switch (value['architecture']) {
      'amd64' => VisualArchitecture.amd64,
      'arm64' => VisualArchitecture.arm64,
      'other' => VisualArchitecture.other,
      _ => throw const LarenorServerException('invalid_response'),
    };
    VisualCpuSupport support(Object? raw) => switch (raw) {
      'supported' => VisualCpuSupport.supported,
      'unsupported' => VisualCpuSupport.unsupported,
      'unknown' => VisualCpuSupport.unknown,
      'not_applicable' => VisualCpuSupport.notApplicable,
      _ => throw const LarenorServerException('invalid_response'),
    };
    final arm64 = value['arm64'];
    final reason = value['reason'];
    final detectorState = switch (value['detectorState']) {
      'unavailable' => VisualDetectorState.unavailable,
      'degraded' => VisualDetectorState.degraded,
      'ready' => VisualDetectorState.ready,
      _ => throw const LarenorServerException('invalid_response'),
    };
    final training = value['trainingSupported']! as bool;
    final inference = value['inferenceSupported']! as bool;
    if (arm64 is! bool ||
        arm64 != (architecture == VisualArchitecture.arm64) ||
        reason is! String ||
        !const {
          'detector_worker_not_configured',
          'cpu_requirements_unmet',
          'arm64_unverified',
          'capability_unverified',
          'worker_stale',
          'ready',
        }.contains(reason)) {
      throw const LarenorServerException('invalid_response');
    }
    final avx = support(value['avx']);
    final avx2 = support(value['avx2']);
    final capabilityConsistent = switch (architecture) {
      VisualArchitecture.arm64 =>
        avx == VisualCpuSupport.notApplicable &&
            avx2 == VisualCpuSupport.notApplicable &&
            const {
              'arm64_unverified',
              'ready',
              'worker_stale',
            }.contains(reason),
      VisualArchitecture.amd64 =>
        avx != VisualCpuSupport.notApplicable &&
            avx2 != VisualCpuSupport.notApplicable &&
            reason != 'arm64_unverified',
      VisualArchitecture.other =>
        avx == VisualCpuSupport.unknown &&
            avx2 == VisualCpuSupport.unknown &&
            reason == 'capability_unverified',
    };
    if (!capabilityConsistent) {
      throw const LarenorServerException('invalid_response');
    }
    final detectorConsistent = switch (detectorState) {
      VisualDetectorState.ready => inference && reason == 'ready',
      VisualDetectorState.degraded => inference && reason == 'worker_stale',
      VisualDetectorState.unavailable =>
        !inference && reason != 'ready' && reason != 'worker_stale',
    };
    if (!detectorConsistent) {
      throw const LarenorServerException('invalid_response');
    }
    return VisualEngineCapability(
      architecture: architecture,
      avx: avx,
      avx2: avx2,
      arm64: arm64,
      reason: reason,
      detectorState: detectorState,
      trainingSupported: training,
      inferenceSupported: inference,
    );
  }

  CameraVisualSensor _sensor(Object? raw, {required int version}) {
    final value = serverObject(raw);
    if (value.length != (version == 1 ? 16 : 19) ||
        value['schemaVersion'] != version ||
        value['accessControlEligible'] != false) {
      throw const LarenorServerException('invalid_response');
    }
    String identity(String key) {
      final item = value[key];
      if (item is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(item)) {
        throw const LarenorServerException('invalid_response');
      }
      return item;
    }

    int revision(String key) {
      final item = value[key];
      if (item is! int || item < 1) {
        throw const LarenorServerException('invalid_response');
      }
      return item;
    }

    final label = value['label'];
    final unsafeLabel =
        label is String &&
        label.runes.any(
          (value) =>
              value < 32 ||
              (value >= 127 && value <= 159) ||
              (value >= 0xd800 && value <= 0xdfff) ||
              (value >= 0x202a && value <= 0x202e) ||
              (value >= 0x2066 && value <= 0x2069) ||
              value == 0xfeff,
        );
    if (label is! String ||
        label.trim() != label ||
        label.isEmpty ||
        label.length > 80 ||
        unsafeLabel) {
      throw const LarenorServerException('invalid_response');
    }
    final state = switch (value['state']) {
      'on' when version == 2 => VisualSensorState.on,
      'off' when version == 2 => VisualSensorState.off,
      'unknown' => VisualSensorState.unknown,
      _ => throw const LarenorServerException('invalid_response'),
    };
    final status = switch (value['status']) {
      'ready' when version == 2 => VisualSensorStatus.ready,
      'degraded' when version == 2 => VisualSensorStatus.degraded,
      'unavailable' => VisualSensorStatus.unavailable,
      _ => throw const LarenorServerException('invalid_response'),
    };
    final reason = value['reason'];
    final confidence = value['confidenceBps'];
    final count = value['count'];
    final automation = value['automationEligible'];
    if (reason is! String ||
        !const {
          'trusted_frame',
          'provider_degraded',
          'missing_frame',
          'corrupt_frame',
          'wrong_camera_frame',
          'stale_frame',
          'no_trusted_frame',
        }.contains(reason) ||
        confidence is! int ||
        confidence < 0 ||
        confidence > 10000 ||
        count is! int ||
        count < 0 ||
        count > 1000 ||
        automation is! bool ||
        (reason != 'trusted_frame' && automation)) {
      throw const LarenorServerException('invalid_response');
    }
    int? timestamp(String key) {
      final item = value[key];
      if (item == null) return null;
      if (item is! int || item < 0) {
        throw const LarenorServerException('invalid_response');
      }
      return item;
    }

    final observedAt = version == 2 ? timestamp('observedAtMs') : null;
    final staleAt = version == 2 ? timestamp('staleAtMs') : null;
    final digest = version == 2 ? value['evidenceDigest'] : null;
    final empty = observedAt == null;
    final projectionConsistent =
        empty == (staleAt == null) &&
        empty == (digest == null) &&
        (empty || staleAt! > observedAt) &&
        switch (status) {
          VisualSensorStatus.ready =>
            !empty &&
                state != VisualSensorState.unknown &&
                reason == 'trusted_frame',
          VisualSensorStatus.degraded =>
            !empty &&
                state == VisualSensorState.unknown &&
                const {
                  'provider_degraded',
                  'missing_frame',
                  'corrupt_frame',
                  'wrong_camera_frame',
                  'stale_frame',
                }.contains(reason),
          VisualSensorStatus.unavailable =>
            empty &&
                state == VisualSensorState.unknown &&
                reason == 'no_trusted_frame' &&
                confidence == 0 &&
                count == 0 &&
                !automation,
        };
    if (!projectionConsistent ||
        (digest != null &&
            (digest is! String ||
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest))) ||
        (version == 1 &&
            (state != VisualSensorState.unknown ||
                status != VisualSensorStatus.unavailable ||
                reason != 'no_trusted_frame' ||
                confidence != 0 ||
                count != 0 ||
                automation))) {
      throw const LarenorServerException('invalid_response');
    }
    return CameraVisualSensor(
      ruleId: identity('ruleId'),
      ruleRevision: revision('ruleRevision'),
      cameraId: identity('cameraId'),
      pipelineId: identity('pipelineId'),
      pipelineRevision: revision('pipelineRevision'),
      modelId: identity('modelId'),
      modelRevision: revision('modelRevision'),
      label: label,
      state: state,
      status: status,
      reason: reason,
      observedAtMs: observedAt,
      staleAtMs: staleAt,
      evidenceDigest: digest as String?,
      confidenceBps: confidence,
      count: count,
      automationEligible: automation,
    );
  }

  @override
  void retire() => _retired = true;
}

final class AccountCameraVisualSensorGateway
    implements CameraVisualSensorGateway {
  AccountCameraVisualSensorGateway({
    required ServerAccountController account,
    required bool Function() isCurrent,
  }) : _account = account,
       _current = isCurrent,
       _generation = account.generation,
       _session = account.session,
       _context = account.session?.context;

  final ServerAccountController _account;
  final bool Function() _current;
  final int _generation;
  final ServerSession? _session;
  final ServerContext? _context;
  bool _retired = false;

  bool _valid() =>
      !_retired &&
      _account.isCurrent(_generation) &&
      identical(_account.session, _session) &&
      _account.session?.context == _context &&
      _account.session?.user.canAdminister == true &&
      _current();

  @override
  Future<CameraVisualSensorSummary> load() async {
    if (!_valid()) throw const LarenorServerException('cancelled');
    return _account.withSession((api, session) async {
      if (!_valid() || !identical(session, _session)) {
        throw const LarenorServerException('cancelled');
      }
      final gateway = CameraVisualSensorApi(api, session, isCurrent: _valid);
      try {
        return await gateway.load();
      } finally {
        gateway.retire();
      }
    });
  }

  @override
  void retire() => _retired = true;
}
