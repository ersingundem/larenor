import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../../media_catalog/data/server_media_catalog_api.dart';
import '../../media_catalog/domain/server_media_catalog_models.dart';
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

  Future<ServerMediaCatalogPage> resolveVerifiedRow({
    required ServerAccountMediaRows rows,
    required ServerMediaRowItem item,
    bool Function()? current,
  }) async {
    _requireCurrent(current);
    final selected = [
      ...rows.rows.recent,
      ...rows.rows.resume,
    ].where((candidate) => identical(candidate, item)).length;
    if (selected != 1) {
      throw const LarenorServerException('invalid_request');
    }
    final catalog = await ServerMediaCatalogApi(
      api,
      token,
    ).discoverTarget(current: current);
    if (catalog.installationId != rows.installationId ||
        catalog.installationRevision != rows.installationRevision) {
      throw const LarenorServerException('invalid_response');
    }
    _requireCurrent(current);
    final requestId = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const LarenorServerException('invalid_request');
    }
    try {
      final response = _object(
        await api.request(
          'POST',
          '/media/rows/resolve',
          token: token,
          body: {
            'requestId': requestId,
            'installationId': rows.installationId,
            'expectedInstallationRevision': rows.installationRevision,
            'expectedBindingRevision': rows.bindingRevision,
            'expectedSnapshotRevision': catalog.snapshotRevision,
            'expectedJellyfinServiceRevision': catalog.jellyfinServiceRevision,
            'itemId': item.itemId,
          },
        ),
        {'requestId', 'bindingRevision', 'catalog'},
      );
      _requireCurrent(current);
      if (response['requestId'] != requestId ||
          response['bindingRevision'] != rows.bindingRevision) {
        throw const FormatException();
      }
      final page = ServerMediaCatalogPage.fromJson(
        response['catalog'],
        operation: ServerMediaCatalogOperation.browse,
        mediaKind: null,
      );
      if (page.installationId != rows.installationId ||
          page.installationRevision != rows.installationRevision ||
          page.snapshotRevision != catalog.snapshotRevision ||
          page.jellyfinServiceRevision != catalog.jellyfinServiceRevision ||
          page.offset != 0 ||
          page.total != 1 ||
          page.nextOffset != null ||
          page.items.length != 1 ||
          page.items.single.itemId != item.itemId ||
          page.items.single.kind !=
              (item.kind == ServerMediaRowKind.movie
                  ? ServerMediaCatalogKind.movie
                  : ServerMediaCatalogKind.episode)) {
        throw const FormatException();
      }
      return page;
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

  static Map<String, dynamic> _object(Object? value, Set<String> keys) {
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !value.keys.every(keys.contains)) {
      throw const FormatException();
    }
    return value;
  }
}
