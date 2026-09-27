import 'dart:math';
import 'dart:typed_data';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../../media_catalog/domain/server_media_catalog_models.dart';
import '../domain/server_offline_media_models.dart';

final class ServerOfflineMediaApi {
  ServerOfflineMediaApi(this.api, this.session, {String Function()? requestId})
    : _requestId = requestId ?? _randomId;

  final LarenorServerApi api;
  final ServerSession session;
  final String Function() _requestId;

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  String _id() {
    final value = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  ServerOfflineMediaManifest _manifest(Object? response) {
    final map = serverObject(response);
    if (map.length != 1 || !map.containsKey('manifest')) {
      throw const LarenorServerException('invalid_response');
    }
    try {
      return ServerOfflineMediaManifest.fromJson(
        map['manifest'],
        session: session,
      );
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<ServerOfflineMediaManifest> create(
    ServerMediaCatalogPage page,
    ServerMediaCatalogItem item, {
    required int availableBytes,
    required int quotaBytes,
  }) async {
    final expires = DateTime.now().toUtc().add(const Duration(days: 7));
    return _manifest(
      await api.request(
        'POST',
        '/media/offline/grants',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestId': _id(),
          'installationId': page.installationId,
          'expectedInstallationRevision': page.installationRevision,
          'expectedSnapshotRevision': page.snapshotRevision,
          'expectedJellyfinServiceRevision': page.jellyfinServiceRevision,
          'itemId': item.itemId,
          'mediaKey': item.mediaKey,
          'expiresAt': expires.millisecondsSinceEpoch ~/ 1000,
          'storageQuotaBytes': quotaBytes,
          'storageAvailableBytes': availableBytes,
        },
      ),
    );
  }

  Future<Uint8List> chunk(ServerOfflineMediaManifest manifest) =>
      api.requestOfflineMediaChunk(
        token: session.accessToken,
        grantId: manifest.grantId,
        body: {
          'schemaVersion': 1,
          'requestId': _id(),
          'expectedRevision': manifest.revision,
          'offset': manifest.downloadedBytes,
        },
      );

  Future<ServerOfflineMediaManifest> progress(
    ServerOfflineMediaManifest manifest,
    int downloadedBytes, {
    String? sha256,
  }) async => _manifest(
    await api.request(
      'POST',
      '/media/offline/grants/${manifest.grantId}/progress',
      token: session.accessToken,
      body: {
        'schemaVersion': 1,
        'requestId': _id(),
        'expectedRevision': manifest.revision,
        'downloadedBytes': downloadedBytes,
        'contentSha256': sha256,
      },
    ),
  );

  Future<ServerOfflineMediaManifest> revoke(
    ServerOfflineMediaManifest manifest,
  ) async => _manifest(
    await api.request(
      'POST',
      '/media/offline/grants/${manifest.grantId}/revoke',
      token: session.accessToken,
      body: {
        'schemaVersion': 1,
        'requestId': _id(),
        'expectedRevision': manifest.revision,
      },
    ),
  );
}
