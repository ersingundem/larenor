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
      final body = <String, dynamic>{
        'schemaVersion': 1,
        'requestId': _requestId(),
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
      return _decodeReceipt(_object(response['receipt']));
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
    final decision = _object(raw['decision']);
    final privacy = _object(raw['privacyBoundary']);
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
    final targets = {
      for (final item in _objects(decision['targets']))
        _identity(
          _object(item)['camera'] is Map
              ? _object(_object(item)['camera'])['cameraId']
              : null,
        ): _object(
          item,
        ),
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
          final scope = _object(target['camera']);
          final observed = readbacks[id]!;
          final current = _object(observed['mode']);
          final desired = _object(target['mode']);
          final support = supports[id]!;
          if (_object(observed['camera'])['bindingId'] != scope['bindingId'] ||
              _object(support['camera'])['bindingId'] != scope['bindingId']) {
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
      reason: _text(decision['reason'], 40),
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

  CameraApplyReceipt _decodeReceipt(Map<String, dynamic> raw) {
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
    if (!const {
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
          final state = switch (value['status']) {
            'applied' => CameraApplyState.applied,
            'skipped' => CameraApplyState.skipped,
            'failed' => CameraApplyState.failed,
            'unknown' => CameraApplyState.unknown,
            _ => throw const LarenorServerException('invalid_response'),
          };
          return CameraApplyResult(
            cameraId: _identity(value['cameraId']),
            state: state,
            code: _text(value['code'], 40),
          );
        })
        .toList(growable: false);
    if (results.isEmpty || results.length > 64) {
      throw const LarenorServerException('invalid_response');
    }
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
