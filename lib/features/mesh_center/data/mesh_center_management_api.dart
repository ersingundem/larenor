import 'dart:math';

import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/mesh_center_models.dart';

abstract interface class MeshCenterManagementApi {
  Future<MeshCenterSnapshot> load(MeshClientAuthority authority);

  Future<MeshFirmwareUpdatePreview> preview(
    MeshClientAuthority authority, {
    required MeshCenterSnapshot snapshot,
    required MeshClientDevice device,
    required MeshFirmwareOffer firmware,
  });

  Future<MeshFirmwareUpdateResult> confirm(
    MeshClientAuthority authority,
    MeshFirmwareUpdatePreview preview,
  );

  Future<MeshFirmwareUpdateResult> readback(
    MeshClientAuthority authority, {
    required String requestId,
  });
}

/// Authenticated, route-owned bridge to the F55 Core contract.
final class CoreMeshCenterManagementApi implements MeshCenterManagementApi {
  CoreMeshCenterManagementApi({
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
  MeshCenterSnapshot? _snapshot;
  Map<String, dynamic>? _topology;
  Map<String, dynamic>? _catalog;
  bool _bootstrapPending = false;
  bool _retired = false;
  final Map<String, MeshFirmwareUpdatePreview> _previews = {};

  ServerSession? get boundSession => _session;
  MeshClientAuthority? get authority => _snapshot?.authority;

  void retire() {
    _retired = true;
    _session = null;
    _snapshot = null;
    _topology = null;
    _catalog = null;
    _previews.clear();
  }

  void _check() {
    try {
      if (!_retired && isCurrent()) return;
    } catch (_) {
      // A route authority failure never preserves the network capability.
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
      '/admin/mesh-center/${context.coreId}/${context.homeId}';

  Future<MeshCenterSnapshot> bootstrap() async {
    _check();
    if (_session != null || _bootstrapPending) {
      throw const LarenorServerException('cancelled');
    }
    _bootstrapPending = true;
    try {
      final value = await account.withSession((api, session) async {
        _check();
        final context = session.context;
        if (!session.user.canAdminister || context == null) {
          throw const LarenorServerException('forbidden');
        }
        _session = session;
        return _decodeSnapshot(
          _envelope(
            await api.request(
              'GET',
              _base(context),
              token: session.accessToken,
            ),
            'snapshot',
          ),
          session,
        );
      });
      _snapshot = value;
      return value;
    } catch (_) {
      retire();
      rethrow;
    } finally {
      _bootstrapPending = false;
    }
  }

  MeshCenterSnapshot _decodeSnapshot(
    Map<String, dynamic> value,
    ServerSession session,
  ) {
    _exact(value, const {
      'schemaVersion',
      'authority',
      'topology',
      'interference',
      'catalog',
      'health',
    });
    if (_integer(value['schemaVersion'], min: 1, max: 1) != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final context = session.context!;
    final rawAuthority = serverObject(value['authority']);
    final authority = MeshClientAuthority(
      coreId: _identity(rawAuthority['coreId']),
      homeId: _identity(rawAuthority['homeId']),
      accountId: _identity(rawAuthority['accountId']),
      sessionFamilyId: _identity(rawAuthority['sessionFamilyId']),
      routeId: routeId,
      homeRevision: _integer(rawAuthority['homeRevision']),
      accountRevision: _integer(rawAuthority['accountRevision']),
      memberRevision: _integer(rawAuthority['memberRevision']),
      sessionRevision: sessionRevision,
      routeRevision: routeRevision,
      admin: rawAuthority['role'] == 'admin',
      canUpdate: _boolean(rawAuthority['canUpdateMesh']),
    );
    if (authority.coreId != context.coreId ||
        authority.homeId != context.homeId ||
        authority.accountId != session.user.id ||
        rawAuthority['active'] != true ||
        rawAuthority['canObserveMesh'] != true ||
        !authority.admin) {
      throw const LarenorServerException('invalid_response');
    }

    final topology = serverObject(value['topology']);
    final interference = serverObject(value['interference']);
    final catalog = serverObject(value['catalog']);
    final health = serverObject(value['health']);
    final coordinator = serverObject(topology['coordinator']);
    final entries = _objects(catalog['entries']);
    final expiresAt = _time(catalog['expiresAtMs']);
    final devices = _objects(topology['devices']).map((raw) {
      final protocol = switch (raw['protocol']) {
        'zigbee' => MeshProtocol.zigbee,
        'thread' => MeshProtocol.thread,
        _ => throw const LarenorServerException('invalid_response'),
      };
      final manufacturer = _text(raw['manufacturer'], 64);
      final model = _text(raw['model'], 64);
      final hardware = _text(raw['hardwareRevision'], 64);
      final installed = _version(raw['firmwareVersion']);
      final candidates =
          entries.where((entry) {
            final hardwareVersions = _strings(
              entry['compatibleHardwareRevisions'],
              32,
            );
            final sourceVersions = _strings(entry['sourceVersions'], 64);
            return protocol == MeshProtocol.zigbee &&
                entry['protocol'] == 'zigbee' &&
                entry['manufacturer'] == manufacturer &&
                entry['model'] == model &&
                hardwareVersions.contains(hardware) &&
                sourceVersions.contains(installed) &&
                _compareVersions(_version(entry['version']), installed) > 0;
          }).toList()..sort(
            (a, b) => _compareVersions(
              _version(b['version']),
              _version(a['version']),
            ),
          );
      final offer = candidates.isEmpty
          ? null
          : MeshFirmwareOffer(
              catalogId: _identity(catalog['catalogId']),
              catalogRevision: '${_integer(catalog['revision'], min: 1)}',
              catalogProviderRevision:
                  '${_integer(catalog['providerRevision'], min: 1)}',
              firmwareId: _identity(candidates.first['firmwareId']),
              targetVersion: _version(candidates.first['version']),
              firmwareSha256: _digest(candidates.first['sha256']),
              signedMetadataVerified: true,
              compatible: true,
              expiresAt: expiresAt,
            );
      final revision = _integer(raw['revision'], min: 1);
      return MeshClientDevice(
        deviceId: _identity(raw['deviceId']),
        name: '$manufacturer $model',
        deviceRevision: '$revision',
        expectedResultRevision: '${revision + 1}',
        providerRevision: '${_integer(raw['providerRevision'], min: 1)}',
        routeRevision: '${_integer(raw['routeRevision'], min: 1)}',
        protocol: protocol,
        manufacturer: manufacturer,
        model: model,
        hardwareRevision: hardware,
        installedVersion: installed,
        powerSource: switch (raw['powerSource']) {
          'mains' => MeshPowerSource.mains,
          'battery' => MeshPowerSource.battery,
          _ => throw const LarenorServerException('invalid_response'),
        },
        batteryPercent: raw['batteryPercent'] == null
            ? null
            : _integer(raw['batteryPercent'], min: 0, max: 100),
        reachable: _boolean(raw['reachable']),
        updating: _boolean(raw['updating']),
        routeDepth: _integer(raw['routeDepth'], min: 1, max: 32),
        lastSeenAt: _time(raw['lastSeenAtMs']),
        update: offer,
      );
    }).toList();
    final advisory = serverObject(health['channelAdvisory']);
    final borderRouters = _objects(topology['borderRouters']);
    final offlineRouters = _strings(health['offlineBorderRouterIds'], 32);
    final snapshot = MeshCenterSnapshot(
      authority: authority,
      topologyRevision: '${_integer(topology['revision'], min: 1)}',
      topologyProviderRevision:
          '${_integer(topology['providerRevision'], min: 1)}',
      coordinatorRevision: '${_integer(coordinator['revision'], min: 1)}',
      interferenceRevision: '${_integer(interference['revision'], min: 1)}',
      capturedAt: _time(topology['capturedAtMs']),
      health: switch (health['status']) {
        'healthy' => MeshHealthState.healthy,
        'degraded' => MeshHealthState.degraded,
        'unavailable' => MeshHealthState.unavailable,
        _ => throw const LarenorServerException('invalid_response'),
      },
      coordinatorOnline: _boolean(coordinator['online']),
      channel: _integer(coordinator['channel'], min: 11, max: 26),
      recommendedChannel: _integer(
        advisory['recommendedChannel'],
        min: 11,
        max: 26,
      ),
      channelUtilizationPercent: _integer(
        advisory['currentUtilizationPercent'],
        min: 0,
        max: 100,
      ),
      recommendedUtilizationPercent: _integer(
        advisory['recommendedUtilizationPercent'],
        min: 0,
        max: 100,
      ),
      borderRouterCount: borderRouters.length,
      offlineBorderRouterCount: offlineRouters.length,
      devices: devices,
    );
    if (!snapshot.isCoherentAt(DateTime.now())) {
      throw const LarenorServerException('invalid_response');
    }
    _topology = Map.unmodifiable(topology);
    _catalog = Map.unmodifiable(catalog);
    return snapshot;
  }

  Future<MeshCenterSnapshot> _refresh(MeshClientAuthority expected) =>
      _bound((api, session) async {
        final value = _decodeSnapshot(
          _envelope(
            await api.request(
              'GET',
              _base(session.context!),
              token: session.accessToken,
            ),
            'snapshot',
          ),
          session,
        );
        if (value.authority != expected) {
          retire();
          throw const LarenorServerException('cancelled');
        }
        _snapshot = value;
        return value;
      });

  @override
  Future<MeshCenterSnapshot> load(MeshClientAuthority authority) async {
    _check();
    final cached = _snapshot;
    if (cached == null || cached.authority != authority) {
      throw const LarenorServerException('cancelled');
    }
    if (_bootstrapPending) return cached;
    _bootstrapPending = true;
    try {
      return await _refresh(authority);
    } finally {
      _bootstrapPending = false;
    }
  }

  @override
  Future<MeshFirmwareUpdatePreview> preview(
    MeshClientAuthority authority, {
    required MeshCenterSnapshot snapshot,
    required MeshClientDevice device,
    required MeshFirmwareOffer firmware,
  }) => _bound((api, session) async {
    final current = _snapshot;
    if (!identical(current, snapshot) ||
        current?.authority != authority ||
        !identical(device.update, firmware) ||
        !current!.devices.any((value) => identical(value, device)) ||
        _topology == null ||
        _catalog == null) {
      throw const LarenorServerException('cancelled');
    }
    final requestId = _requestId();
    final response = await api.request(
      'POST',
      '${_base(session.context!)}/previews',
      token: session.accessToken,
      body: {
        'schemaVersion': 1,
        'authority': _authorityJson(authority),
        'topology': _topology,
        'catalog': _catalog,
        'deviceId': device.deviceId,
        'firmwareId': firmware.firmwareId,
        'requestId': requestId,
      },
    );
    final value = _previewFromJson(_envelope(response, 'preview'), authority);
    if (value.requestId != requestId ||
        !value.isExactFor(
          authority,
          snapshot,
          device,
          firmware,
          DateTime.now(),
        )) {
      throw const LarenorServerException('invalid_response');
    }
    if (_previews.length >= 16) _previews.remove(_previews.keys.first);
    _previews[value.requestId] = value;
    return value;
  });

  @override
  Future<MeshFirmwareUpdateResult> confirm(
    MeshClientAuthority authority,
    MeshFirmwareUpdatePreview preview,
  ) => _bound((api, session) async {
    if (_snapshot?.authority != authority ||
        !identical(_previews[preview.requestId], preview)) {
      throw const LarenorServerException('cancelled');
    }
    final response = await api.request(
      'POST',
      '${_base(session.context!)}/previews/${preview.requestId}/confirm',
      token: session.accessToken,
      body: {
        'schemaVersion': 1,
        'authority': _authorityJson(authority),
        'preview': _previewJson(preview),
        'confirmationToken': preview.confirmationProof,
      },
    );
    return _resultFromJson(_envelope(response, 'result'), authority, preview);
  });

  @override
  Future<MeshFirmwareUpdateResult> readback(
    MeshClientAuthority authority, {
    required String requestId,
  }) => _bound((api, session) async {
    final preview = _previews[requestId];
    if (_snapshot?.authority != authority ||
        preview == null ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const LarenorServerException('cancelled');
    }
    final response = await api.request(
      'GET',
      '${_base(session.context!)}/results/$requestId',
      token: session.accessToken,
    );
    final value = _resultFromJson(
      _envelope(response, 'result'),
      authority,
      preview,
    );
    _previews.remove(requestId);
    return value;
  });
}

Map<String, dynamic> _authorityJson(MeshClientAuthority value) => {
  'schemaVersion': 1,
  'coreId': value.coreId,
  'homeId': value.homeId,
  'homeRevision': value.homeRevision,
  'accountId': value.accountId,
  'accountRevision': value.accountRevision,
  'memberRevision': value.memberRevision,
  'sessionFamilyId': value.sessionFamilyId,
  'role': value.admin ? 'admin' : 'member',
  'active': true,
  'canObserveMesh': true,
  'canUpdateMesh': value.canUpdate,
};

MeshFirmwareUpdatePreview _previewFromJson(
  Map<String, dynamic> value,
  MeshClientAuthority authority,
) => MeshFirmwareUpdatePreview(
  authority: authority,
  requestId: _identity(value['requestId']),
  topologyRevision: '${_integer(value['topologyRevision'], min: 1)}',
  topologyProviderRevision:
      '${_integer(value['topologyProviderRevision'], min: 1)}',
  coordinatorRevision: '${_integer(value['coordinatorRevision'], min: 1)}',
  deviceId: _identity(value['deviceId']),
  expectedDeviceRevision:
      '${_integer(value['expectedDeviceRevision'], min: 1)}',
  expectedResultRevision:
      '${_integer(value['expectedResultRevision'], min: 1)}',
  expectedProviderRevision:
      '${_integer(value['expectedProviderRevision'], min: 1)}',
  expectedRouteRevision: '${_integer(value['expectedRouteRevision'], min: 1)}',
  catalogId: _identity(value['catalogId']),
  catalogRevision: '${_integer(value['catalogRevision'], min: 1)}',
  catalogProviderRevision:
      '${_integer(value['catalogProviderRevision'], min: 1)}',
  firmwareId: _identity(value['firmwareId']),
  firmwareSha256: _digest(value['firmwareSha256']),
  targetVersion: _version(value['targetVersion']),
  expiresAt: _time(value['expiresAtMs']),
  confirmationProof: _digest(value['confirmationToken']),
);

Map<String, dynamic> _previewJson(MeshFirmwareUpdatePreview value) => {
  'schemaVersion': 1,
  'requestId': value.requestId,
  'coreId': value.authority.coreId,
  'homeId': value.authority.homeId,
  'homeRevision': value.authority.homeRevision,
  'accountId': value.authority.accountId,
  'accountRevision': value.authority.accountRevision,
  'memberRevision': value.authority.memberRevision,
  'sessionFamilyId': value.authority.sessionFamilyId,
  'topologyRevision': int.parse(value.topologyRevision),
  'topologyProviderRevision': int.parse(value.topologyProviderRevision),
  'coordinatorRevision': int.parse(value.coordinatorRevision),
  'deviceId': value.deviceId,
  'expectedDeviceRevision': int.parse(value.expectedDeviceRevision),
  'expectedResultRevision': int.parse(value.expectedResultRevision),
  'expectedProviderRevision': int.parse(value.expectedProviderRevision),
  'expectedRouteRevision': int.parse(value.expectedRouteRevision),
  'catalogId': value.catalogId,
  'catalogRevision': int.parse(value.catalogRevision),
  'catalogProviderRevision': int.parse(value.catalogProviderRevision),
  'firmwareId': value.firmwareId,
  'firmwareSha256': value.firmwareSha256,
  'targetVersion': value.targetVersion,
  'expiresAtMs': value.expiresAt.millisecondsSinceEpoch,
  'confirmationToken': value.confirmationProof,
};

MeshFirmwareUpdateResult _resultFromJson(
  Map<String, dynamic> value,
  MeshClientAuthority authority,
  MeshFirmwareUpdatePreview preview,
) {
  final status = switch (value['status']) {
    'confirmed' => MeshUpdateStatus.confirmed,
    'uncertain' => MeshUpdateStatus.uncertain,
    _ => throw const LarenorServerException('invalid_response'),
  };
  if (_identity(value['requestId']) != preview.requestId ||
      value['readbackVerified'] is! bool) {
    throw const LarenorServerException('invalid_response');
  }
  final verified = value['readbackVerified'] as bool;
  if (status == MeshUpdateStatus.uncertain) {
    if (verified || value['readback'] != null) {
      throw const LarenorServerException('invalid_response');
    }
    return MeshFirmwareUpdateResult(
      authority: authority,
      requestId: preview.requestId,
      deviceId: preview.deviceId,
      previousDeviceRevision: preview.expectedDeviceRevision,
      deviceRevision: preview.expectedResultRevision,
      providerRevision: preview.expectedProviderRevision,
      routeRevision: preview.expectedRouteRevision,
      installedVersion: preview.targetVersion,
      installedSha256: preview.firmwareSha256,
      status: status,
      readbackVerified: false,
    );
  }
  final readback = serverObject(value['readback']);
  return MeshFirmwareUpdateResult(
    authority: authority,
    requestId: _identity(readback['requestId']),
    deviceId: _identity(readback['deviceId']),
    previousDeviceRevision:
        '${_integer(readback['previousDeviceRevision'], min: 1)}',
    deviceRevision: '${_integer(readback['deviceRevision'], min: 1)}',
    providerRevision: '${_integer(readback['providerRevision'], min: 1)}',
    routeRevision: '${_integer(readback['routeRevision'], min: 1)}',
    installedVersion: _version(readback['installedVersion']),
    installedSha256: _digest(readback['installedSha256']),
    status: status,
    readbackVerified: verified,
  );
}

void _exact(Map<String, dynamic> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
    throw const LarenorServerException('invalid_response');
  }
}

String _identity(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

String _digest(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

String _text(Object? value, int max) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > max ||
      value.runes.any((unit) => unit < 32 || unit == 127)) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

String _version(Object? value) {
  final text = _text(value, 32);
  if (!RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')
      .hasMatch(text)) {
    throw const LarenorServerException('invalid_response');
  }
  return text;
}

int _compareVersions(String left, String right) {
  final a = left.split('.').map(int.parse).toList();
  final b = right.split('.').map(int.parse).toList();
  for (var index = 0; index < 3; index++) {
    final compared = a[index].compareTo(b[index]);
    if (compared != 0) return compared;
  }
  return 0;
}

int _integer(Object? value, {int min = 0, int max = 0x7fffffffffffffff}) {
  if (value is! int || value < min || value > max) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

bool _boolean(Object? value) {
  if (value is! bool) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

DateTime _time(Object? value) =>
    DateTime.fromMillisecondsSinceEpoch(_integer(value), isUtc: true);

List<Map<String, dynamic>> _objects(Object? value) {
  if (value is! List || value.length > 2048) {
    throw const LarenorServerException('invalid_response');
  }
  return value.map(serverObject).toList(growable: false);
}

List<String> _strings(Object? value, int maxItems) {
  if (value is! List || value.length > maxItems) {
    throw const LarenorServerException('invalid_response');
  }
  final result = value.map((item) => _text(item, 64)).toList(growable: false);
  if (result.toSet().length != result.length) {
    throw const LarenorServerException('invalid_response');
  }
  return result;
}
