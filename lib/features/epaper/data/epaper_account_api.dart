import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../../shared/network/server_bound_client.dart';
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
    this._binary,
    this.authority,
  );

  final ServerAccountController account;
  final ServerContext context;
  final bool Function() isCurrent;
  final String routeId;
  final int _generation;
  final ServerEndpoint _endpoint;
  final LarenorServerApi _api;
  final ServerBoundClient _binary;
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
        ServerBoundClient(baseUrl: captured.endpoint.baseUrl),
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
  Future<List<EpaperSourceDevice>> discoverSources(
    EpaperClientAuthority presented,
  ) async {
    _exact(presented);
    if (!authority.canManage) throw const EpaperApiException('forbidden');
    final raw = await _request(
      'POST',
      '$_adminRoot/sources',
      body: authority.toJson(),
    );
    if (raw?['authority'] is! Map<String, dynamic> ||
        EpaperClientAuthority.fromJson(
              raw!['authority'] as Map<String, dynamic>,
            ) !=
            authority ||
        raw['devices'] is! List ||
        (raw['devices'] as List).length > 100) {
      throw const EpaperApiException('invalid_response');
    }
    final values = (raw['devices'] as List)
        .map(
          (item) => EpaperSourceDevice.fromJson(item as Map<String, dynamic>),
        )
        .toList(growable: false);
    if (values.any((item) => !item.isValid) ||
        values.map((item) => item.deviceId).toSet().length != values.length) {
      throw const EpaperApiException('invalid_response');
    }
    return List.unmodifiable(values);
  }

  @override
  Future<EpaperDeviceStatus> map(
    EpaperClientAuthority presented,
    EpaperDeviceMappingDraft draft,
  ) async {
    _exact(presented);
    if (!authority.canManage || !draft.isValid || !draft.hasVerifiedSource) {
      throw const EpaperApiException('forbidden');
    }
    final value = await _request(
      'PUT',
      '$_adminRoot/sources/${draft.deviceId}',
      body: {
        ...authority.toJson(),
        'expectedMappingRevision': 0,
        'serviceId': draft.serviceId,
        'serviceRevision': draft.serviceRevision,
        'expectedSourceRevision': draft.sourceRevision,
        'name': draft.name,
        'title': draft.title,
        'value': draft.value,
        'ttlSeconds': 900,
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
  Future<Uint8List> artifact(
    EpaperClientAuthority presented,
    EpaperCommandPreview preview,
  ) async {
    _exact(presented);
    if (preview.authority != authority ||
        preview.artifactPath == null ||
        preview.artifactDigest == null) {
      throw const EpaperApiException('invalid_response');
    }
    final session = await _session();
    final request = http.Request('GET', _endpoint.api(preview.artifactPath!))
      ..headers['Authorization'] = 'Bearer ${session.accessToken}';
    final response = await _binary
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 ||
        response.headers['content-type']?.split(';').first != 'image/jpeg') {
      throw const EpaperApiException('invalid_response');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (builder.length + chunk.length > 2 * 1024 * 1024) {
        throw const EpaperApiException('invalid_response');
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length < 16 ||
        sha256.convert(bytes).toString() != preview.artifactDigest) {
      throw const EpaperApiException('invalid_response');
    }
    await _session();
    return bytes;
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

  void close() {
    if (_closed) return;
    _closed = true;
    _api.close();
    _binary.close();
  }
}
