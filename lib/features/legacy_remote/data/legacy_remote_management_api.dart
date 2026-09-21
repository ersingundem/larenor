import 'dart:math';

import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/legacy_remote_models.dart';

abstract interface class LegacyRemoteManagementApi {
  Future<List<LegacyRemoteDevice>> list(LegacyRemoteAuthority authority);

  Future<LegacyRemoteCommandPreview> preview(
    LegacyRemoteAuthority authority, {
    required LegacyRemoteDevice device,
    required LegacyRemoteCommandDefinition command,
    required int repeats,
    required int holdMs,
  });

  Future<LegacyRemoteCommandResult> confirm(
    LegacyRemoteAuthority authority,
    LegacyRemoteCommandPreview preview,
  );

  Future<LegacyRemoteCommandResult> readback(
    LegacyRemoteAuthority authority, {
    required String requestId,
  });
}

/// Authenticated, route-owned bridge to the F56 Core HTTP contract.
final class CoreLegacyRemoteManagementApi implements LegacyRemoteManagementApi {
  CoreLegacyRemoteManagementApi({
    required this.account,
    required this.routeId,
    required this.sessionRevision,
    required this.routeRevision,
    required this.isCurrent,
    Random? random,
  }) : _random = random ?? Random.secure();

  final ServerAccountController account;
  final String routeId;
  final int sessionRevision;
  final int routeRevision;
  final bool Function() isCurrent;
  final Random _random;
  ServerSession? _session;
  LegacyRemoteCatalog? _catalog;
  bool _bootstrapPending = false;
  bool _retired = false;
  final Map<String, LegacyRemoteCommandPreview> _previews = {};

  ServerSession? get boundSession => _session;
  LegacyRemoteAuthority? get authority => _catalog?.authority;

  void retire() {
    _retired = true;
    _session = null;
    _catalog = null;
    _previews.clear();
  }

  void _check() {
    try {
      if (!_retired && isCurrent()) return;
    } catch (_) {
      // Route authority failures never preserve a network capability.
    }
    retire();
    throw const LarenorServerException('cancelled');
  }

  String _requestId() =>
      List.generate(32, (_) => _random.nextInt(16).toRadixString(16)).join();

  Map<String, dynamic> _envelope(Map<String, dynamic>? value, String key) {
    if (value == null || value.length != 1 || !value.containsKey(key)) {
      throw const LarenorServerException('invalid_response');
    }
    return serverObject(value[key]);
  }

  bool _sameSession(ServerSession current, ServerSession expected) =>
      identical(current, expected) &&
      identical(account.session, expected) &&
      current.user.canAdminister &&
      current.context != null;

  Future<T> _bound<T>(
    Future<T> Function(LarenorServerApi api, ServerSession session) action,
  ) async {
    _check();
    final expected = _session;
    if (expected == null) throw const LarenorServerException('cancelled');
    return account.withSession((api, session) async {
      _check();
      if (!_sameSession(session, expected)) {
        retire();
        throw const LarenorServerException('cancelled');
      }
      final result = await action(api, session);
      _check();
      if (!_sameSession(session, expected)) {
        retire();
        throw const LarenorServerException('cancelled');
      }
      return result;
    });
  }

  String _base(ServerContext context) =>
      '/admin/legacy-remotes/${context.coreId}/${context.homeId}';

  Future<LegacyRemoteCatalog> bootstrap() async {
    _check();
    if (_session != null || _bootstrapPending) {
      throw const LarenorServerException('cancelled');
    }
    _bootstrapPending = true;
    try {
      final catalog = await account.withSession((api, session) async {
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
        _check();
        if (!_sameSession(session, session)) {
          throw const LarenorServerException('cancelled');
        }
        final value = LegacyRemoteCatalog.fromJson(
          _envelope(response, 'catalog'),
          routeId: routeId,
          sessionRevision: sessionRevision,
          routeRevision: routeRevision,
        );
        if (value.authority.coreId != context.coreId ||
            value.authority.homeId != context.homeId ||
            value.authority.accountId != session.user.id) {
          throw const LarenorServerException('invalid_response');
        }
        return value;
      });
      _catalog = catalog;
      return catalog;
    } catch (_) {
      retire();
      rethrow;
    } finally {
      _bootstrapPending = false;
    }
  }

  Future<LegacyRemoteCatalog> _refresh(LegacyRemoteAuthority expected) =>
      _bound((api, session) async {
        final response = await api.request(
          'GET',
          _base(session.context!),
          token: session.accessToken,
        );
        final value = LegacyRemoteCatalog.fromJson(
          _envelope(response, 'catalog'),
          routeId: routeId,
          sessionRevision: sessionRevision,
          routeRevision: routeRevision,
        );
        if (value.authority != expected) {
          retire();
          throw const LarenorServerException('cancelled');
        }
        _catalog = value;
        return value;
      });

  @override
  Future<List<LegacyRemoteDevice>> list(LegacyRemoteAuthority authority) async {
    _check();
    final cached = _catalog;
    if (cached == null || cached.authority != authority) {
      throw const LarenorServerException('cancelled');
    }
    if (!_bootstrapPending) {
      _bootstrapPending = true;
      try {
        return (await _refresh(authority)).devices;
      } finally {
        _bootstrapPending = false;
      }
    }
    return cached.devices;
  }

  LegacyRemoteDevice _currentDevice(LegacyRemoteDevice device) {
    final catalog = _catalog;
    if (catalog == null || device.authority != catalog.authority) {
      throw const LarenorServerException('cancelled');
    }
    final current = catalog.devices.where(
      (value) => value.deviceId == device.deviceId,
    );
    if (current.length != 1 || !identical(current.single, device)) {
      throw const LarenorServerException('cancelled');
    }
    return current.single;
  }

  @override
  Future<LegacyRemoteCommandPreview> preview(
    LegacyRemoteAuthority authority, {
    required LegacyRemoteDevice device,
    required LegacyRemoteCommandDefinition command,
    required int repeats,
    required int holdMs,
  }) => _bound((api, session) async {
    if (_catalog?.authority != authority ||
        !_currentDevice(device).commands.contains(command)) {
      throw const LarenorServerException('cancelled');
    }
    final requestId = _requestId();
    final response = await api.request(
      'POST',
      '${_base(session.context!)}/previews',
      token: session.accessToken,
      body: {
        'schemaVersion': 1,
        'authority': authority.toCoreJson(),
        'requestId': requestId,
        'deviceId': device.deviceId,
        'expectedDeviceRevision': device.deviceRevision,
        'providerId': device.providerId,
        'expectedProviderRevision': device.providerRevision,
        'bridgeId': device.bridgeId,
        'expectedBridgeRevision': device.bridgeRevision,
        'profileId': device.profileId,
        'expectedProfileRevision': device.profileRevision,
        'codeSetId': device.codeSetId,
        'expectedCodeSetRevision': device.codeSetRevision,
        'bindingId': command.bindingId,
        'commandKey': legacyRemoteCommandWire(command.key),
        'repeats': repeats,
        'holdMs': holdMs,
      },
    );
    final value = LegacyRemoteCommandPreview.fromJson(
      _envelope(response, 'preview'),
      authority,
    );
    if (value.requestId != requestId ||
        !value.isExactFor(authority, device, command, DateTime.now())) {
      throw const LarenorServerException('invalid_response');
    }
    if (_previews.length >= 16) _previews.remove(_previews.keys.first);
    _previews[value.requestId] = value;
    return value;
  });

  @override
  Future<LegacyRemoteCommandResult> confirm(
    LegacyRemoteAuthority authority,
    LegacyRemoteCommandPreview preview,
  ) => _bound((api, session) async {
    if (_catalog?.authority != authority ||
        !identical(_previews[preview.requestId], preview)) {
      throw const LarenorServerException('cancelled');
    }
    final response = await api.request(
      'POST',
      '${_base(session.context!)}/previews/${preview.requestId}/confirm',
      token: session.accessToken,
      body: {
        'schemaVersion': 1,
        'authority': authority.toCoreJson(),
        'preview': preview.toCoreJson(),
        'confirmationToken': preview.confirmationToken,
      },
    );
    return LegacyRemoteCommandResult.fromJson(
      _envelope(response, 'result'),
      preview,
    );
  });

  @override
  Future<LegacyRemoteCommandResult> readback(
    LegacyRemoteAuthority authority, {
    required String requestId,
  }) => _bound((api, session) async {
    final preview = _previews[requestId];
    if (_catalog?.authority != authority ||
        preview == null ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const LarenorServerException('cancelled');
    }
    final response = await api.request(
      'GET',
      '${_base(session.context!)}/results/$requestId',
      token: session.accessToken,
    );
    final value = LegacyRemoteCommandResult.fromJson(
      _envelope(response, 'result'),
      preview,
    );
    _previews.remove(requestId);
    return value;
  });
}
