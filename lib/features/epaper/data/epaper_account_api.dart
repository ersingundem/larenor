import 'dart:async';
import 'dart:math';

import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/epaper_management_models.dart';
import 'epaper_management_api.dart';

final class EpaperApiException implements Exception {
  const EpaperApiException(this.code);
  final String code;
}

/// One account/Core/home/route-owned F58 transport. Commands are never retried.
final class EpaperAccountApi implements EpaperManagementApi {
  EpaperAccountApi._(
    this.account,
    this.context,
    this.isCurrent,
    this.routeId,
    this._generation,
    this._endpoint,
    this._api,
    this.authority,
  );

  final ServerAccountController account;
  final ServerContext context;
  final bool Function() isCurrent;
  final String routeId;
  final int _generation;
  final ServerEndpoint _endpoint;
  final LarenorServerApi _api;
  final EpaperClientAuthority authority;
  bool _closed = false;

  static Future<EpaperAccountApi> connect({
    required ServerAccountController account,
    required ServerContext context,
    required String routeId,
    required bool Function() isCurrent,
    ServerApiFactory? apiFactory,
  }) async {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(routeId)) {
      throw const EpaperApiException('invalid_route');
    }
    final generation = account.generation;
    final captured = account.session;
    if (captured == null || captured.context != context || !isCurrent()) {
      throw const EpaperApiException('authority_changed');
    }
    final api =
        (apiFactory ?? ((endpoint) => LarenorServerApi(endpoint: endpoint)))(
          captured.endpoint,
        );
    try {
      final session = await account.ensureSession();
      if (!isCurrent() || !account.isCurrent(generation)) {
        throw const EpaperApiException('authority_changed');
      }
      final value = await api.request(
        'GET',
        '/epaper/${context.coreId}/${context.homeId}/authority',
        token: session.accessToken,
      );
      final authority = EpaperClientAuthority.fromJson(value!);
      if (!isCurrent() ||
          !account.isCurrent(generation) ||
          authority.coreId != context.coreId ||
          authority.homeId != context.homeId ||
          authority.accountId != session.user.id ||
          session.context != context) {
        throw const EpaperApiException('authority_changed');
      }
      return EpaperAccountApi._(
        account,
        context,
        isCurrent,
        routeId,
        generation,
        captured.endpoint,
        api,
        authority,
      );
    } catch (_) {
      api.close();
      rethrow;
    }
  }

  String get _root => '/epaper/${context.coreId}/${context.homeId}';
  String get _adminRoot => '/admin/epaper/${context.coreId}/${context.homeId}';

  Future<ServerSession> _session() async {
    if (_closed || !isCurrent() || !account.isCurrent(_generation)) {
      throw const EpaperApiException('authority_changed');
    }
    final session = await account.ensureSession();
    if (_closed ||
        !isCurrent() ||
        !account.isCurrent(_generation) ||
        session.context != context ||
        session.endpoint.baseUrl != _endpoint.baseUrl ||
        session.user.id != authority.accountId) {
      throw const EpaperApiException('authority_changed');
    }
    return session;
  }

  Future<Map<String, dynamic>?> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool empty = false,
  }) async {
    try {
      final session = await _session();
      final value = await _api.request(
        method,
        path,
        token: session.accessToken,
        body: body,
        allowEmpty: empty,
      );
      await _session();
      return value;
    } on LarenorServerException catch (error) {
      if (const {
        'connection_failed',
        'timeout',
        'server_unavailable',
      }.contains(error.code)) {
        throw TimeoutException(error.code);
      }
      throw EpaperApiException(error.code);
    }
  }

  void _exact(EpaperClientAuthority presented) {
    if (presented != authority) {
      throw const EpaperApiException('authority_changed');
    }
  }

  @override
  Future<List<EpaperDeviceStatus>> list(EpaperClientAuthority presented) async {
    _exact(presented);
    final raw = await _request(
      'POST',
      '$_root/devices',
      body: authority.toJson(),
    );
    final values = raw?['devices'];
    if (values is! List || values.length > 100) {
      throw const EpaperApiException('invalid_response');
    }
    return List.unmodifiable(
      values.map((value) {
        if (value is! Map<String, dynamic>) {
          throw const EpaperApiException('invalid_response');
        }
        final device = EpaperDeviceStatus.fromJson(value);
        if (device.authority != authority) {
          throw const EpaperApiException('authority_changed');
        }
        return device;
      }),
    );
  }

  @override
  Future<EpaperDeviceStatus> map(
    EpaperClientAuthority presented,
    EpaperDeviceMappingDraft draft,
  ) async {
    _exact(presented);
    if (!authority.canManage || !draft.isValid) {
      throw const EpaperApiException('forbidden');
    }
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final layoutId = _randomId(), dataId = _randomId();
    final policyId = _randomId(), slotId = _randomId();
    final common = {
      'schemaVersion': 1,
      'coreId': context.coreId,
      'homeId': context.homeId,
    };
    final value = await _request(
      'PUT',
      '$_adminRoot/devices/${draft.deviceId}',
      body: {
        ...authority.toJson(),
        'expectedMappingRevision': 0,
        'name': draft.name,
        'ttlSeconds': 900,
        'device': {
          ...common,
          'deviceId': draft.deviceId,
          'revision': 1,
          'bridgeRevision': 1,
          'width': draft.width,
          'height': draft.height,
          'supportedColors': ['black', 'white'],
          'active': true,
          'connectivity': 'unknown',
          'batteryPercent': 0,
          'lastSeenAtMs': now,
        },
        'layout': {
          ...common,
          'layoutId': layoutId,
          'revision': 1,
          'width': draft.width,
          'height': draft.height,
          'colors': ['black', 'white'],
          'slots': [
            {
              'schemaVersion': 1,
              'slotId': slotId,
              'kind': 'clock',
              'column': 0,
              'row': 0,
              'columnSpan': 8,
              'rowSpan': 8,
            },
          ],
        },
        'data': {
          ...common,
          'dataId': dataId,
          'revision': 1,
          'providerRevision': 1,
          'capturedAtMs': now,
          'classification': 'shared',
          'cards': [
            {
              'schemaVersion': 1,
              'slotId': slotId,
              'kind': 'clock',
              'label': 'Larenor',
              'value': '--:--',
              'unit': null,
              'status': 'offline',
              'accent': 'black',
            },
          ],
        },
        'policy': {
          ...common,
          'policyId': policyId,
          'revision': 1,
          'allowedKinds': ['clock'],
          'allowedColors': ['black', 'white'],
          'maxCards': 1,
          'maxTtlSeconds': 3600,
          'sharedContentOnly': true,
        },
      },
    );
    return EpaperDeviceStatus.fromJson(value!);
  }

  @override
  Future<EpaperCommandPreview> preview(
    EpaperClientAuthority presented, {
    required String deviceId,
    required String expectedDeviceRevision,
    required EpaperManagementAction action,
  }) async {
    _exact(presented);
    final value = await _request(
      'POST',
      '$_adminRoot/devices/$deviceId/previews',
      body: {
        ...authority.toJson(),
        'expectedDeviceRevision': expectedDeviceRevision,
        'action': action.name,
      },
    );
    return EpaperCommandPreview.fromJson(value!);
  }

  @override
  Future<EpaperCommandReceipt> confirm(
    EpaperClientAuthority presented,
    EpaperCommandPreview preview,
  ) async {
    _exact(presented);
    if (!preview.isExactFor(
      authority,
      await readback(authority, deviceId: preview.deviceId),
      preview.action,
      DateTime.now(),
    )) {
      throw const EpaperApiException('authority_changed');
    }
    return EpaperCommandReceipt.fromJson(
      (await _request(
        'POST',
        '$_adminRoot/previews/${preview.requestId}/confirm',
        body: authority.toJson(),
      ))!,
    );
  }

  @override
  Future<void> cancel(
    EpaperClientAuthority presented,
    EpaperCommandPreview preview,
  ) async {
    _exact(presented);
    await _request(
      'DELETE',
      '$_adminRoot/previews/${preview.requestId}',
      body: authority.toJson(),
      empty: true,
    );
  }

  @override
  Future<EpaperDeviceStatus> readback(
    EpaperClientAuthority presented, {
    required String deviceId,
  }) async {
    _exact(presented);
    final value = await _request(
      'POST',
      '$_root/devices/$deviceId',
      body: authority.toJson(),
    );
    final device = EpaperDeviceStatus.fromJson(value!);
    if (device.authority != authority || device.deviceId != deviceId) {
      throw const EpaperApiException('authority_changed');
    }
    return device;
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _api.close();
  }
}
