import 'dart:math';

import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/camera_profile_models.dart';

abstract interface class CameraProfileApi {
  Future<CameraProfileSnapshot> bootstrap();
  Future<CameraApplyReceipt> apply(CameraProfileSnapshot snapshot);
  void retire();
}

final class CoreCameraProfileApi implements CameraProfileApi {
  CoreCameraProfileApi({
    required this.account,
    required this.routeId,
    required this.sessionRevision,
    required this.routeRevision,
    required this.isCurrent,
    Random? random,
  }) : _random = random ?? Random.secure();

  final ServerAccountController account;
  final String routeId;
  final int sessionRevision, routeRevision;
  final bool Function() isCurrent;
  final Random _random;
  ServerSession? _session;
  CameraProfileSnapshot? _snapshot;
  Map<String, dynamic>? _wire;
  bool _retired = false;

  ServerSession? get boundSession => _session;

  void _check() {
    var current = false;
    try {
      current = !_retired && isCurrent();
    } catch (_) {
      current = false;
    }
    if (current) return;
    retire();
    throw const LarenorServerException('cancelled');
  }

  @override
  void retire() {
    _retired = true;
    _session = null;
    _snapshot = null;
    _wire = null;
  }

  String _requestId() =>
      List.generate(32, (_) => _random.nextInt(16).toRadixString(16)).join();
  String _base(ServerContext context) =>
      '/admin/camera-profiles/${context.coreId}/${context.homeId}';

  @override
  Future<CameraProfileSnapshot> bootstrap() async {
    _check();
    final cached = _snapshot;
    if (cached != null) return cached;
    if (_session != null) throw const LarenorServerException('cancelled');
    return account.withSession((api, session) async {
      _check();
      final context = session.context;
      if (!session.user.canAdminister || context == null) {
        throw const LarenorServerException('forbidden');
      }
      _session = session;
      final response = await api.request(
        'GET',
        _base(context),
        token: session.accessToken,
      );
      _checkSession(session);
      final envelope = _object(response);
      _keys(envelope, const {'snapshot'});
      final raw = _object(envelope['snapshot']);
      final decoded = _decode(raw, session);
      _wire = raw;
      _snapshot = decoded;
      return decoded;
    });
  }

  @override
  Future<CameraApplyReceipt> apply(CameraProfileSnapshot snapshot) async {
    _check();
    if (!identical(snapshot, _snapshot) ||
        snapshot.authority != _snapshot?.authority) {
      throw const LarenorServerException('cancelled');
    }
    final raw = _wire;
    final session = _session;
    if (raw == null || session == null) {
      throw const LarenorServerException('cancelled');
    }
    return account.withSession((api, current) async {
      _checkSession(current, expected: session);
      final context = current.context!;
      final requestId = _requestId();
      final body = <String, dynamic>{
        'schemaVersion': 1,
        'requestId': requestId,
        for (final key in const [
          'authority',
          'policy',
          'signal',
          'decision',
          'readbacks',
          'support',
        ])
          key: raw[key],
      };
      final response = _object(
        await api.request(
          'POST',
          '${_base(context)}/apply',
          token: current.accessToken,
          body: body,
        ),
      );
      _checkSession(current, expected: session);
      _keys(response, const {'receipt'});
      return _decodeReceipt(
        _object(response['receipt']),
        expectedRequestId: requestId,
        expectedSnapshot: snapshot,
      );
    });
  }

  void _checkSession(ServerSession current, {ServerSession? expected}) {
    _check();
    final target = expected ?? _session;
    if (target == null ||
        !identical(current, target) ||
        !identical(account.session, target) ||
        current.context == null) {
      retire();
      throw const LarenorServerException('cancelled');
    }
  }

  CameraProfileSnapshot _decode(
    Map<String, dynamic> raw,
    ServerSession session,
  ) {
    _keys(raw, const {
      'schemaVersion',
      'authority',
      'policy',
      'signal',
      'decision',
      'readbacks',
      'support',
      'privacyBoundary',
    });
    if (_integer(raw['schemaVersion']) != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final authorityRaw = _object(raw['authority']);
    final policy = _object(raw['policy']);
    final signal = _object(raw['signal']);
    final decision = _object(raw['decision']);
    final privacy = _object(raw['privacyBoundary']);
    _keys(authorityRaw, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'homeRevision',
      'accountId',
      'accountRevision',
      'sessionFamilyId',
      'role',
      'active',
      'canManageCameraProfiles',
    });
    _keys(policy, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'profileId',
      'profileRevision',
      'presenceSourceId',
      'presenceSourceRevision',
      'cameras',
      'enterDelayMs',
      'exitDelayMs',
      'hysteresisMs',
      'presenceMaxAgeMs',
      'atHomeMode',
      'awayMode',
      'failSafeMode',
      'active',
    });
    _keys(signal, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'sourceId',
      'sourceRevision',
      'signalRevision',
      'observedAtMs',
      'state',
    });
    _keys(decision, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'homeRevision',
      'profileId',
      'profileRevision',
      'policyHash',
      'actorAccountId',
      'accountRevision',
      'sessionFamilyId',
      'presenceSourceId',
      'presenceSourceRevision',
      'signalRevision',
      'evaluatedAtMs',
      'reason',
      'mode',
      'targets',
    });
    _keys(privacy, const {
      'microphoneDisabled',
      'cameraHardwareDisabled',
      'otherRecordersDisabled',
    });
    final context = session.context!;
    final authority = CameraProfileAuthority(
      coreId: _identity(authorityRaw['coreId']),
      homeId: _identity(authorityRaw['homeId']),
      accountId: _identity(authorityRaw['accountId']),
      sessionFamilyId: _identity(authorityRaw['sessionFamilyId']),
      profileId: _identity(policy['profileId']),
      homeRevision: _integer(authorityRaw['homeRevision']),
      accountRevision: _integer(authorityRaw['accountRevision']),
      profileRevision: _integer(policy['profileRevision']),
      sessionRevision: sessionRevision,
      routeRevision: routeRevision,
      routeId: routeId,
      canManage:
          authorityRaw['active'] == true &&
          authorityRaw['canManageCameraProfiles'] == true &&
          authorityRaw['role'] == 'admin',
    );
    if (!authority.isBounded ||
        authority.coreId != context.coreId ||
        authority.homeId != context.homeId ||
        authority.accountId != session.user.id ||
        authority.sessionFamilyId.isEmpty) {
      throw const LarenorServerException('invalid_response');
    }
    if (_integer(authorityRaw['schemaVersion']) != 1 ||
        _integer(policy['schemaVersion']) != 1 ||
        _integer(signal['schemaVersion']) != 1 ||
        _integer(decision['schemaVersion']) != 1 ||
        policy['coreId'] != authority.coreId ||
        policy['homeId'] != authority.homeId ||
        policy['active'] != true ||
        decision['coreId'] != authority.coreId ||
        decision['homeId'] != authority.homeId ||
        decision['homeRevision'] != authority.homeRevision ||
        decision['profileId'] != authority.profileId ||
        decision['profileRevision'] != authority.profileRevision ||
        decision['actorAccountId'] != authority.accountId ||
        decision['accountRevision'] != authority.accountRevision ||
        decision['sessionFamilyId'] != authority.sessionFamilyId ||
        signal['coreId'] != authority.coreId ||
        signal['homeId'] != authority.homeId ||
        signal['sourceId'] != policy['presenceSourceId'] ||
        signal['sourceRevision'] != policy['presenceSourceRevision'] ||
        decision['presenceSourceId'] != signal['sourceId'] ||
        decision['presenceSourceRevision'] != signal['sourceRevision'] ||
        decision['signalRevision'] != signal['signalRevision']) {
      throw const LarenorServerException('invalid_response');
    }
    final policyScopes = {
      for (final value in _objects(policy['cameras']))
        _identity(_scope(value)['cameraId']): _scope(value),
    };
    _mode(policy['atHomeMode']);
    _mode(policy['awayMode']);
    _mode(policy['failSafeMode']);
    final decisionMode = _mode(decision['mode']);
    final reason = _text(decision['reason'], 40);
    if (!const {
          'presence_home',
          'presence_away',
          'presence_unknown',
          'presence_stale',
          'presence_stabilizing',
          'manual_override',
          'manual_override_expired',
        }.contains(reason) ||
        decision['policyHash'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(decision['policyHash'] as String) ||
        !const {'home', 'away', 'unknown'}.contains(signal['state'])) {
      throw const LarenorServerException('invalid_response');
    }
    final targets = {
      for (final item in _objects(decision['targets']))
        _identity(_scope(_object(item)['camera'])['cameraId']): _object(item),
    };
    final readbacks = {
      for (final item in _objects(raw['readbacks']))
        _identity(_object(_object(item)['camera'])['cameraId']): _object(item),
    };
    final supports = {
      for (final item in _objects(raw['support']))
        _identity(_object(_object(item)['camera'])['cameraId']): _object(item),
    };
    if (targets.isEmpty ||
        policyScopes.length != targets.length ||
        policyScopes.keys.toSet().difference(targets.keys.toSet()).isNotEmpty ||
        targets.keys.toSet().length != targets.length ||
        targets.keys.toSet().difference(readbacks.keys.toSet()).isNotEmpty ||
        targets.keys.toSet().difference(supports.keys.toSet()).isNotEmpty ||
        readbacks.length != targets.length ||
        supports.length != targets.length) {
      throw const LarenorServerException('invalid_response');
    }
    final cameras = targets.entries
        .map((entry) {
          final id = entry.key;
          final target = entry.value;
          _keys(target, const {'schemaVersion', 'camera', 'mode'});
          if (_integer(target['schemaVersion']) != 1) {
            throw const LarenorServerException('invalid_response');
          }
          final scope = _scope(target['camera']);
          final observed = readbacks[id]!;
          _keys(observed, const {
            'schemaVersion',
            'coreId',
            'homeId',
            'camera',
            'stateRevision',
            'mode',
            'observedAtMs',
          });
          final current = _mode(observed['mode']);
          final desired = _mode(target['mode']);
          final support = supports[id]!;
          _keys(support, const {
            'schemaVersion',
            'camera',
            'displayName',
            'providerRevision',
            'recordingSupported',
            'detectionSupported',
            'verifiedAtMs',
          });
          final observedScope = _scope(observed['camera']);
          final supportScope = _scope(support['camera']);
          if (_integer(observed['schemaVersion']) != 1 ||
              _integer(support['schemaVersion']) != 1 ||
              !_sameMap(scope, policyScopes[id]!) ||
              !_sameMap(desired, decisionMode) ||
              !_sameMap(observedScope, scope) ||
              !_sameMap(supportScope, scope) ||
              observed['coreId'] != authority.coreId ||
              observed['homeId'] != authority.homeId ||
              _integer(observed['observedAtMs']) >
                  _integer(decision['evaluatedAtMs']) ||
              _integer(support['verifiedAtMs']) >
                  _integer(decision['evaluatedAtMs'])) {
            throw const LarenorServerException('invalid_response');
          }
          return CameraProfileCamera(
            id: id,
            name: _text(support['displayName'], 80),
            cameraRevision: _integer(scope['cameraRevision']),
            bindingRevision: _integer(scope['bindingRevision']),
            providerRevision: _integer(support['providerRevision']),
            stateRevision: _integer(observed['stateRevision']),
            recordingSupported: _boolean(support['recordingSupported']),
            detectionSupported: _boolean(support['detectionSupported']),
            currentRecording: _setting(current['recording']),
            currentDetection: _setting(current['detection']),
            desiredRecording: _setting(desired['recording']),
            desiredDetection: _setting(desired['detection']),
          );
        })
        .toList(growable: false);
    final snapshot = CameraProfileSnapshot(
      authority: authority,
      reason: reason,
      cameras: cameras,
      microphoneDisabled: _boolean(privacy['microphoneDisabled']),
      cameraHardwareDisabled: _boolean(privacy['cameraHardwareDisabled']),
      otherRecordersDisabled: _boolean(privacy['otherRecordersDisabled']),
    );
    if (!snapshot.makesNoHardwarePrivacyClaim) {
      throw const LarenorServerException('invalid_response');
    }
    return snapshot;
  }

  CameraApplyReceipt _decodeReceipt(
    Map<String, dynamic> raw, {
    required String expectedRequestId,
    required CameraProfileSnapshot expectedSnapshot,
  }) {
    _keys(raw, const {
      'schemaVersion',
      'requestId',
      'profileId',
      'profileRevision',
      'status',
      'results',
      'createdAtMs',
    });
    final status = _text(raw['status'], 40);
    if (_integer(raw['schemaVersion']) != 1 ||
        raw['requestId'] != expectedRequestId ||
        raw['profileId'] != expectedSnapshot.authority.profileId ||
        raw['profileRevision'] != expectedSnapshot.authority.profileRevision ||
        !const {
          'applied',
          'already_applied',
          'partial',
          'failed',
          'unknown',
        }.contains(status)) {
      throw const LarenorServerException('invalid_response');
    }
    final results = _objects(raw['results'])
        .map((item) {
          final value = _object(item);
          _keys(value, const {
            'schemaVersion',
            'commandId',
            'cameraId',
            'status',
            'code',
            'readback',
          });
          if (_integer(value['schemaVersion']) != 1) {
            throw const LarenorServerException('invalid_response');
          }
          final state = switch (value['status']) {
            'applied' => CameraApplyState.applied,
            'skipped' => CameraApplyState.skipped,
            'failed' => CameraApplyState.failed,
            'unknown' => CameraApplyState.unknown,
            _ => throw const LarenorServerException('invalid_response'),
          };
          _identity(value['commandId']);
          final cameraId = _identity(value['cameraId']);
          final code = _text(value['code'], 40);
          if (!const {
            'applied',
            'already_applied',
            'readback_mismatch',
            'worker_ack_unknown',
            'worker_response_invalid',
            'provider_unsupported',
          }.contains(code)) {
            throw const LarenorServerException('invalid_response');
          }
          final camera = expectedSnapshot.cameras
              .where((item) => item.id == cameraId)
              .firstOrNull;
          final unsupportedChange =
              camera != null &&
              ((!camera.recordingSupported &&
                      camera.currentRecording != camera.desiredRecording) ||
                  (!camera.detectionSupported &&
                      camera.currentDetection != camera.desiredDetection));
          if (code == 'provider_unsupported' && !unsupportedChange) {
            throw const LarenorServerException('invalid_response');
          }
          final readback = value['readback'];
          final needsReadback =
              code == 'applied' || code == 'readback_mismatch';
          if (needsReadback != (readback != null)) {
            throw const LarenorServerException('invalid_response');
          }
          if (readback != null) {
            final returned = _object(readback);
            _keys(returned, const {
              'schemaVersion',
              'commandId',
              'camera',
              'stateRevision',
              'mode',
              'observedAtMs',
            });
            if (_integer(returned['schemaVersion']) != 1 ||
                returned['commandId'] != value['commandId'] ||
                _scope(returned['camera'])['cameraId'] != cameraId) {
              throw const LarenorServerException('invalid_response');
            }
            _integer(returned['stateRevision']);
            _integer(returned['observedAtMs']);
            _mode(returned['mode']);
          }
          final statusMatchesCode = switch (code) {
            'applied' => state == CameraApplyState.applied,
            'already_applied' => state == CameraApplyState.skipped,
            'worker_ack_unknown' => state == CameraApplyState.unknown,
            _ => state == CameraApplyState.failed,
          };
          if (!statusMatchesCode) {
            throw const LarenorServerException('invalid_response');
          }
          return CameraApplyResult(
            cameraId: cameraId,
            state: state,
            code: code,
          );
        })
        .toList(growable: false);
    final ids = results.map((item) => item.cameraId).toSet();
    final expectedIds = expectedSnapshot.cameras.map((item) => item.id).toSet();
    final states = results.map((item) => item.state).toSet();
    final aggregate = states.length > 1
        ? 'partial'
        : switch (states.singleOrNull) {
            CameraApplyState.applied => 'applied',
            CameraApplyState.skipped => 'already_applied',
            CameraApplyState.failed => 'failed',
            CameraApplyState.unknown => 'unknown',
            null => '',
          };
    if (results.isEmpty ||
        results.length > 64 ||
        ids.length != results.length ||
        ids.difference(expectedIds).isNotEmpty ||
        expectedIds.difference(ids).isNotEmpty ||
        aggregate != status) {
      throw const LarenorServerException('invalid_response');
    }
    _integer(raw['createdAtMs']);
    return CameraApplyReceipt(
      requestId: _identity(raw['requestId']),
      status: status,
      results: results,
    );
  }

  static Map<String, dynamic> _object(Object? value) {
    if (value is! Map) throw const LarenorServerException('invalid_response');
    return value.map((key, value) {
      if (key is! String) {
        throw const LarenorServerException('invalid_response');
      }
      return MapEntry(key, value);
    });
  }

  static List<dynamic> _objects(Object? value) {
    if (value is! List || value.isEmpty || value.length > 64) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  static Map<String, dynamic> _scope(Object? value) {
    final scope = _object(value);
    _keys(scope, const {
      'schemaVersion',
      'cameraId',
      'cameraRevision',
      'areaId',
      'areaRevision',
      'serviceId',
      'serviceRevision',
      'bindingId',
      'bindingRevision',
    });
    if (_integer(scope['schemaVersion']) != 1) {
      throw const LarenorServerException('invalid_response');
    }
    for (final key in const ['cameraId', 'areaId', 'serviceId', 'bindingId']) {
      _identity(scope[key]);
    }
    for (final key in const [
      'cameraRevision',
      'areaRevision',
      'serviceRevision',
      'bindingRevision',
    ]) {
      if (_integer(scope[key]) < 1) {
        throw const LarenorServerException('invalid_response');
      }
    }
    return scope;
  }

  static Map<String, dynamic> _mode(Object? value) {
    final mode = _object(value);
    _keys(mode, const {'recording', 'detection'});
    _setting(mode['recording']);
    _setting(mode['detection']);
    return mode;
  }

  static bool _sameMap(Map<String, dynamic> left, Map<String, dynamic> right) =>
      left.length == right.length &&
      left.keys.every((key) => left[key] == right[key]);

  static void _keys(Map<String, dynamic> value, Set<String> expected) {
    if (value.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(value.keys.toSet()).isNotEmpty) {
      throw const LarenorServerException('invalid_response');
    }
  }

  static int _integer(Object? value) {
    if (value is! int || value < 0) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  static bool _boolean(Object? value) {
    if (value is! bool) throw const LarenorServerException('invalid_response');
    return value;
  }

  static String _identity(Object? value) {
    if (value is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  static String _text(Object? value, int max) {
    if (value is! String ||
        value.trim() != value ||
        value.isEmpty ||
        value.length > max ||
        value.runes.any((r) => r < 32 || r == 127)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  static CameraSettingValue _setting(Object? value) => switch (value) {
    'enabled' => CameraSettingValue.enabled,
    'paused' => CameraSettingValue.paused,
    'disabled' => CameraSettingValue.disabled,
    _ => throw const LarenorServerException('invalid_response'),
  };
}
