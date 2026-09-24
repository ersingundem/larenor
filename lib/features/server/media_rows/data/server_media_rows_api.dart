import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../../media_catalog/data/server_media_catalog_api.dart';
import '../domain/server_media_rows_models.dart';

final class ServerMediaRowsApi {
  ServerMediaRowsApi(this.api, this.token, {String Function()? requestId})
    : _requestId = requestId ?? _randomId;

  final LarenorServerApi api;
  final String token;
  final String Function() _requestId;

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<ServerAccountMediaRows> readCurrent({bool Function()? current}) async {
    final target = await discoverTarget(current: current);
    return readVerifiedTarget(target: target, current: current);
  }

  Future<ServerMediaRowsTarget> discoverTarget({
    bool Function()? current,
  }) async {
    _requireCurrent(current);
    final catalog = await ServerMediaCatalogApi(
      api,
      token,
    ).discoverTarget(current: current);
    _requireCurrent(current);
    try {
      final response = await api.request(
        'POST',
        '/media/rows/target',
        token: token,
        body: {
          'installationId': catalog.installationId,
          'expectedInstallationRevision': catalog.installationRevision,
        },
      );
      _requireCurrent(current);
      return ServerMediaRowsTarget.fromJson(
        response,
        expectedInstallationId: catalog.installationId,
        expectedInstallationRevision: catalog.installationRevision,
      );
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<ServerAccountMediaRows> readVerifiedTarget({
    required ServerMediaRowsTarget target,
    bool Function()? current,
  }) async {
    _requireCurrent(current);
    final requestId = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const LarenorServerException('invalid_request');
    }
    try {
      final response = await api.request(
        'POST',
        '/media/rows/read',
        token: token,
        body: {
          'requestId': requestId,
          'installationId': target.installationId,
          'expectedInstallationRevision': target.installationRevision,
          'expectedBindingRevision': target.bindingRevision,
        },
      );
      _requireCurrent(current);
      return ServerAccountMediaRows.fromJson(
        response,
        expectedRequestId: requestId,
        expectedInstallationId: target.installationId,
        expectedInstallationRevision: target.installationRevision,
        expectedBindingRevision: target.bindingRevision,
      );
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  }

  static void _requireCurrent(bool Function()? current) {
    if (current == null) return;
    try {
      if (current()) return;
    } catch (_) {
      // A retired owner is indistinguishable from a false owner callback.
    }
    throw const LarenorServerException('retired');
  }
}
