import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_catalog_models.dart';

final class ServerMediaCatalogApi {
  ServerMediaCatalogApi(this.api, this.token, {String Function()? requestId})
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

  Future<ServerMediaCatalogPage> search({
    required String installationId,
    required int expectedInstallationRevision,
    required String query,
    ServerMediaCatalogKind? mediaKind,
    int offset = 0,
    int limit = 24,
  }) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(installationId) ||
        expectedInstallationRevision < 1 ||
        expectedInstallationRevision > 0x7ffffffffffffffe ||
        query.isEmpty ||
        query.length > 80 ||
        query != query.trim() ||
        RegExp(
          r'[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]',
        ).hasMatch(query) ||
        offset < 0 ||
        offset > 4096 ||
        limit < 1 ||
        limit > 50) {
      throw const LarenorServerException('invalid_request');
    }
    final requestId = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const LarenorServerException('invalid_request');
    }
    try {
      final authority = _object(
        await api.request(
          'POST',
          '/admin/media/archive-health/authority',
          token: token,
          body: {
            'requestId': requestId,
            'installationId': installationId,
            'expectedInstallationRevision': expectedInstallationRevision,
          },
        ),
        {
          'requestId',
          'installationId',
          'installationRevision',
          'snapshotRevision',
        },
      );
      if (authority['requestId'] != requestId ||
          authority['installationId'] != installationId ||
          authority['installationRevision'] != expectedInstallationRevision ||
          authority['snapshotRevision'] is! int) {
        throw const FormatException();
      }
      final response = _object(
        await api.request(
          'POST',
          '/admin/media/archive-health/catalog/search',
          token: token,
          body: {
            'requestId': requestId,
            'installationId': installationId,
            'expectedInstallationRevision': expectedInstallationRevision,
            'expectedSnapshotRevision': authority['snapshotRevision'],
            'query': query,
            'mediaKind': mediaKind?.wire,
            'offset': offset,
            'limit': limit,
          },
        ),
        {'requestId', 'catalog'},
      );
      if (response['requestId'] != requestId) throw const FormatException();
      final page = ServerMediaCatalogPage.fromJson(response['catalog']);
      if (page.installationId != installationId ||
          page.installationRevision != expectedInstallationRevision ||
          page.snapshotRevision != authority['snapshotRevision'] ||
          page.offset != offset ||
          page.items.length > limit ||
          mediaKind != null &&
              page.items.any((item) => item.kind != mediaKind)) {
        throw const FormatException();
      }
      return page;
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
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
