import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_catalog_models.dart';

final class ServerMediaCatalogTarget {
  const ServerMediaCatalogTarget._({
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
    required this.jellyfinServiceRevision,
  });

  final String installationId;
  final int installationRevision, snapshotRevision, jellyfinServiceRevision;
}

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

  Future<ServerMediaCatalogTarget> discoverTarget({
    bool Function()? current,
  }) async {
    _requireCurrent(current);
    try {
      final response = _object(
        await api.request('GET', '/media/catalog/target', token: token),
        {
          'schemaVersion',
          'installationId',
          'installationRevision',
          'snapshotRevision',
          'jellyfinServiceRevision',
        },
      );
      _requireCurrent(current);
      if (response['schemaVersion'] is! int || response['schemaVersion'] != 1) {
        throw const FormatException();
      }
      return ServerMediaCatalogTarget._(
        installationId: _id(response['installationId']),
        installationRevision: _revision(response['installationRevision']),
        snapshotRevision: _revision(response['snapshotRevision']),
        jellyfinServiceRevision: _revision(response['jellyfinServiceRevision']),
      );
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<ServerMediaCatalogPage> searchVerifiedTarget({
    required ServerMediaCatalogTarget target,
    required String query,
    ServerMediaCatalogKind? mediaKind,
    int offset = 0,
    int limit = 24,
    ServerMediaCatalogPage? previousPage,
    bool Function()? current,
  }) async {
    _validateSearch(query: query, offset: offset, limit: limit);
    if ((offset == 0) != (previousPage == null) ||
        previousPage != null &&
            (previousPage.nextOffset != offset ||
                previousPage.query != query ||
                previousPage.mediaKind != mediaKind)) {
      throw const LarenorServerException('invalid_request');
    }
    if (previousPage != null &&
        (target.installationId != previousPage.installationId ||
            target.installationRevision != previousPage.installationRevision ||
            target.snapshotRevision != previousPage.snapshotRevision ||
            target.jellyfinServiceRevision !=
                previousPage.jellyfinServiceRevision)) {
      throw const LarenorServerException('invalid_response');
    }
    _requireCurrent(current);
    final page = await _search(
      installationId: target.installationId,
      expectedInstallationRevision: target.installationRevision,
      expectedSnapshotRevision: target.snapshotRevision,
      expectedJellyfinServiceRevision: target.jellyfinServiceRevision,
      query: query,
      mediaKind: mediaKind,
      offset: offset,
      limit: limit,
    );
    _requireCurrent(current);
    return page;
  }

  Future<ServerMediaCatalogPage> searchCurrent({
    required String query,
    ServerMediaCatalogKind? mediaKind,
    int offset = 0,
    int limit = 24,
    ServerMediaCatalogPage? previousPage,
    bool Function()? current,
  }) async {
    _validateSearch(query: query, offset: offset, limit: limit);
    if ((offset == 0) != (previousPage == null) ||
        previousPage != null &&
            (previousPage.nextOffset != offset ||
                previousPage.query != query ||
                previousPage.mediaKind != mediaKind)) {
      throw const LarenorServerException('invalid_request');
    }
    final target = await discoverTarget(current: current);
    return searchVerifiedTarget(
      target: target,
      query: query,
      mediaKind: mediaKind,
      offset: offset,
      limit: limit,
      previousPage: previousPage,
      current: current,
    );
  }

  Future<ServerMediaCatalogPage> browseVerifiedTarget({
    required ServerMediaCatalogTarget target,
    ServerMediaCatalogKind? mediaKind,
    int offset = 0,
    int limit = 24,
    ServerMediaCatalogPage? previousPage,
    bool Function()? current,
  }) async {
    _validatePage(offset: offset, limit: limit);
    if ((offset == 0) != (previousPage == null) ||
        previousPage != null &&
            (previousPage.operation != ServerMediaCatalogOperation.browse ||
                previousPage.nextOffset != offset ||
                previousPage.mediaKind != mediaKind)) {
      throw const LarenorServerException('invalid_request');
    }
    if (previousPage != null &&
        (target.installationId != previousPage.installationId ||
            target.installationRevision != previousPage.installationRevision ||
            target.snapshotRevision != previousPage.snapshotRevision ||
            target.jellyfinServiceRevision !=
                previousPage.jellyfinServiceRevision)) {
      throw const LarenorServerException('invalid_response');
    }
    _requireCurrent(current);
    final page = await _browse(
      installationId: target.installationId,
      expectedInstallationRevision: target.installationRevision,
      expectedSnapshotRevision: target.snapshotRevision,
      expectedJellyfinServiceRevision: target.jellyfinServiceRevision,
      mediaKind: mediaKind,
      offset: offset,
      limit: limit,
    );
    _requireCurrent(current);
    return page;
  }

  Future<ServerMediaCatalogPage> browseCurrent({
    ServerMediaCatalogKind? mediaKind,
    int offset = 0,
    int limit = 24,
    ServerMediaCatalogPage? previousPage,
    bool Function()? current,
  }) async {
    _validatePage(offset: offset, limit: limit);
    final target = await discoverTarget(current: current);
    return browseVerifiedTarget(
      target: target,
      mediaKind: mediaKind,
      offset: offset,
      limit: limit,
      previousPage: previousPage,
      current: current,
    );
  }

  Future<ServerMediaCatalogPage> search({
    required String installationId,
    required int expectedInstallationRevision,
    required String query,
    ServerMediaCatalogKind? mediaKind,
    int offset = 0,
    int limit = 24,
    bool Function()? current,
  }) async {
    _validateSearch(query: query, offset: offset, limit: limit);
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(installationId) ||
        expectedInstallationRevision < 1 ||
        expectedInstallationRevision > 0x7ffffffffffffffe) {
      throw const LarenorServerException('invalid_request');
    }
    final target = await discoverTarget(current: current);
    if (target.installationId != installationId ||
        target.installationRevision != expectedInstallationRevision) {
      throw const LarenorServerException('invalid_response');
    }
    final page = await _search(
      installationId: target.installationId,
      expectedInstallationRevision: target.installationRevision,
      expectedSnapshotRevision: target.snapshotRevision,
      expectedJellyfinServiceRevision: target.jellyfinServiceRevision,
      query: query,
      mediaKind: mediaKind,
      offset: offset,
      limit: limit,
    );
    _requireCurrent(current);
    return page;
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

  static void _validateSearch({
    required String query,
    required int offset,
    required int limit,
  }) {
    if (query.isEmpty ||
        query.length > 80 ||
        query != query.trim() ||
        RegExp(
          r'[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]',
        ).hasMatch(query) ||
        !_validPage(offset: offset, limit: limit)) {
      throw const LarenorServerException('invalid_request');
    }
  }

  static bool _validPage({required int offset, required int limit}) =>
      offset >= 0 && offset <= 4096 && limit >= 1 && limit <= 50;

  static void _validatePage({required int offset, required int limit}) {
    if (!_validPage(offset: offset, limit: limit)) {
      throw const LarenorServerException('invalid_request');
    }
  }

  Future<ServerMediaCatalogPage> _search({
    required String installationId,
    required int expectedInstallationRevision,
    required int expectedSnapshotRevision,
    required int expectedJellyfinServiceRevision,
    required String query,
    ServerMediaCatalogKind? mediaKind,
    required int offset,
    required int limit,
  }) async {
    final requestId = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const LarenorServerException('invalid_request');
    }
    try {
      final response = _object(
        await api.request(
          'POST',
          '/media/catalog/search',
          token: token,
          body: {
            'requestId': requestId,
            'installationId': installationId,
            'expectedInstallationRevision': expectedInstallationRevision,
            'expectedSnapshotRevision': expectedSnapshotRevision,
            'query': query,
            'mediaKind': mediaKind?.wire,
            'offset': offset,
            'limit': limit,
          },
        ),
        {'requestId', 'catalog'},
      );
      if (response['requestId'] != requestId) throw const FormatException();
      final page = ServerMediaCatalogPage.fromJson(
        response['catalog'],
        query: query,
        mediaKind: mediaKind,
      );
      if (page.installationId != installationId ||
          page.installationRevision != expectedInstallationRevision ||
          page.snapshotRevision != expectedSnapshotRevision ||
          page.jellyfinServiceRevision != expectedJellyfinServiceRevision ||
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

  Future<ServerMediaCatalogPage> _browse({
    required String installationId,
    required int expectedInstallationRevision,
    required int expectedSnapshotRevision,
    required int expectedJellyfinServiceRevision,
    ServerMediaCatalogKind? mediaKind,
    required int offset,
    required int limit,
  }) async {
    final requestId = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const LarenorServerException('invalid_request');
    }
    try {
      final response = _object(
        await api.request(
          'POST',
          '/media/catalog/browse',
          token: token,
          body: {
            'requestId': requestId,
            'installationId': installationId,
            'expectedInstallationRevision': expectedInstallationRevision,
            'expectedSnapshotRevision': expectedSnapshotRevision,
            'mediaKind': mediaKind?.wire,
            'offset': offset,
            'limit': limit,
          },
        ),
        {'requestId', 'catalog'},
      );
      if (response['requestId'] != requestId) throw const FormatException();
      final page = ServerMediaCatalogPage.fromJson(
        response['catalog'],
        operation: ServerMediaCatalogOperation.browse,
        mediaKind: mediaKind,
      );
      if (page.installationId != installationId ||
          page.installationRevision != expectedInstallationRevision ||
          page.snapshotRevision != expectedSnapshotRevision ||
          page.jellyfinServiceRevision != expectedJellyfinServiceRevision ||
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

  static String _id(Object? value) {
    if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const FormatException();
    }
    return value;
  }

  static int _revision(Object? value) {
    if (value is! int || value < 1 || value > 0x7ffffffffffffffe) {
      throw const FormatException();
    }
    return value;
  }
}
