import 'dart:math';

import '../../server/data/server_account_controller.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/kiosk_remote_models.dart';

abstract interface class KioskRemoteApi {
  Future<KioskRemoteSnapshot> load();
  Future<KioskRemoteCreated> create(
    KioskRemoteDevice device,
    Set<String> scopes,
  );
  Future<void> revoke(KioskRemotePairing pairing);
  void retire();
}

final class CoreKioskRemoteApi implements KioskRemoteApi {
  CoreKioskRemoteApi({
    required this.account,
    required this.sessionRevision,
    required this.routeRevision,
    required this.isCurrent,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ServerAccountController account;
  final int sessionRevision, routeRevision;
  final bool Function() isCurrent;
  final DateTime Function() _clock;
  ServerSession? _session;
  bool _retired = false;

  ServerSession? get boundSession => _session;

  void _check([ServerSession? session]) {
    var current = false;
    try {
      current = !_retired && isCurrent();
    } catch (_) {
      current = false;
    }
    if (current &&
        (session == null ||
            identical(_session, session) &&
                identical(account.session, session))) {
      return;
    }
    retire();
    throw const LarenorServerException('cancelled');
  }

  String _root(ServerSession session) {
    final context = session.context!;
    return '${context.coreId}/${context.homeId}';
  }

  Future<T> _with<T>(
    Future<T> Function(LarenorServerApi api, ServerSession session) body,
  ) => account.withSession((api, session) async {
    _check();
    if (!session.user.canAdminister || session.context == null) {
      throw const LarenorServerException('forbidden');
    }
    _session ??= session;
    _check(session);
    final value = await body(api, session);
    _check(session);
    return value;
  });

  @override
  Future<KioskRemoteSnapshot> load() => _with((api, session) async {
    final root = _root(session);
    final devicesRaw = _object(
      await api.request(
        'GET',
        '/tablet-fleet/$root/devices',
        token: session.accessToken,
      ),
    );
    final pairingsRaw = _object(
      await api.request(
        'GET',
        '/admin/paired-remote/$root/pairings',
        token: session.accessToken,
      ),
    );
    return KioskRemoteSnapshot(
      devices: _devices(devicesRaw, session.context!),
      pairings: _pairings(pairingsRaw),
    );
  });

  @override
  Future<KioskRemoteCreated> create(
    KioskRemoteDevice device,
    Set<String> scopes,
  ) => _with((api, session) async {
    if (device.state != 'active' ||
        scopes.isEmpty ||
        !const {'read', 'control', 'admin'}.containsAll(scopes)) {
      _invalid();
    }
    final sorted = scopes.toList()..sort();
    final root = _root(session);
    final raw = _object(
      await api.request(
        'POST',
        '/admin/paired-remote/$root/pairings',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestId': _identity(),
          'deviceId': device.id,
          'expectedDeviceRevision': device.revision,
          'name': '${device.name} remote',
          'scopes': sorted,
          'expiresAt':
              _clock().add(const Duration(days: 30)).millisecondsSinceEpoch /
              1000,
        },
      ),
    );
    _keys(raw, const {'pairing', 'token'});
    final token = _text(raw['token'], 43);
    if (token.length != 43 || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      _invalid();
    }
    return KioskRemoteCreated(
      pairing: _pairing(_object(raw['pairing'])),
      token: token,
    );
  });

  @override
  Future<void> revoke(KioskRemotePairing pairing) =>
      _with((api, session) async {
        final root = _root(session);
        await api.request(
          'DELETE',
          '/admin/paired-remote/$root/pairings/${pairing.id}',
          token: session.accessToken,
          queryParameters: {'expectedRevision': '${pairing.revision}'},
          allowEmpty: true,
        );
      });

  @override
  void retire() {
    _retired = true;
    _session = null;
  }

  static List<KioskRemoteDevice> _devices(
    Map<String, dynamic> raw,
    ServerContext context,
  ) {
    _keys(raw, const {'schemaVersion', 'scope', 'tablets'});
    if (_int(raw['schemaVersion']) != 1) _invalid();
    final scope = _object(raw['scope']);
    _keys(scope, const {'schemaVersion', 'coreId', 'homeId'});
    if (_int(scope['schemaVersion']) != 1 ||
        _id(scope['coreId']) != context.coreId ||
        _id(scope['homeId']) != context.homeId) {
      _invalid();
    }
    final items = raw['tablets'];
    if (items is! List || items.length > 256) _invalid();
    return List.unmodifiable(
      items.map((item) {
        final value = _object(item);
        _keys(value, const {
          'schemaVersion',
          'ref',
          'revision',
          'name',
          'platform',
          'managementMode',
          'capabilities',
          'clientVersion',
          'desiredProfileRevision',
          'appliedProfileRevision',
          'state',
          'profileState',
          'lastSeenAt',
        });
        final ref = _object(value['ref']);
        _keys(ref, const {'schemaVersion', 'coreId', 'homeId', 'kind', 'id'});
        if (_int(ref['schemaVersion']) != 1 ||
            _id(ref['coreId']) != context.coreId ||
            _id(ref['homeId']) != context.homeId ||
            ref['kind'] != 'managed_tablet' ||
            value['platform'] != 'android') {
          _invalid();
        }
        final state = _oneOf(value['state'], const {'active', 'revoked'});
        return KioskRemoteDevice(
          id: _id(ref['id']),
          revision: _positive(value['revision']),
          name: _text(value['name'], 80),
          state: state,
        );
      }),
    );
  }

  static List<KioskRemotePairing> _pairings(Map<String, dynamic> raw) {
    _keys(raw, const {'schemaVersion', 'pairings'});
    if (_int(raw['schemaVersion']) != 1) _invalid();
    final items = raw['pairings'];
    if (items is! List || items.length > 128) _invalid();
    return List.unmodifiable(items.map((item) => _pairing(_object(item))));
  }

  static KioskRemotePairing _pairing(Map<String, dynamic> raw) {
    _keys(raw, const {
      'schemaVersion',
      'id',
      'deviceId',
      'revision',
      'name',
      'scopes',
      'state',
      'expiresAt',
      'mqttClientId',
      'mqttTopicPrefix',
    });
    if (_int(raw['schemaVersion']) != 1) _invalid();
    final scopesRaw = raw['scopes'];
    if (scopesRaw is! List || scopesRaw.isEmpty || scopesRaw.length > 3) {
      _invalid();
    }
    final scopes = scopesRaw
        .map((value) => _oneOf(value, const {'read', 'control', 'admin'}))
        .toList();
    if (scopes.toSet().length != scopes.length) _invalid();
    final expires = raw['expiresAt'];
    if (expires is! num || !expires.isFinite || expires < 0) _invalid();
    return KioskRemotePairing(
      id: _id(raw['id']),
      deviceId: _id(raw['deviceId']),
      revision: _positive(raw['revision']),
      name: _text(raw['name'], 80),
      scopes: List.unmodifiable(scopes),
      state: _oneOf(raw['state'], const {'active', 'revoked'}),
      expiresAtMs: (expires * 1000).round(),
      mqttClientId: _text(raw['mqttClientId'], 96),
      mqttTopicPrefix: _text(raw['mqttTopicPrefix'], 96),
    );
  }

  static String _identity() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static Never _invalid() =>
      throw const LarenorServerException('invalid_response');
  static Map<String, dynamic> _object(Object? value) =>
      value is Map<String, dynamic> ? value : _invalid();
  static void _keys(Map<String, dynamic> value, Set<String> expected) {
    if (value.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(value.keys.toSet()).isNotEmpty) {
      _invalid();
    }
  }

  static int _int(Object? value) => value is int ? value : _invalid();
  static int _positive(Object? value) {
    final result = _int(value);
    return result > 0 ? result : _invalid();
  }

  static String _text(Object? value, int max) {
    if (value is! String ||
        value.isEmpty ||
        value.length > max ||
        value != value.trim()) {
      _invalid();
    }
    return value;
  }

  static String _id(Object? value) {
    final result = _text(value, 32);
    return result.length == 32 && RegExp(r'^[0-9a-f]{32}$').hasMatch(result)
        ? result
        : _invalid();
  }

  static String _oneOf(Object? value, Set<String> allowed) {
    final result = _text(value, 64);
    return allowed.contains(result) ? result : _invalid();
  }
}
