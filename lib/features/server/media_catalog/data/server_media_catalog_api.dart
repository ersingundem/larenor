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

  Future<({String installationId, int installationRevision})>
  _discoverTarget() async {
    try {
      final response = _object(
        await api.request(
          'GET',
          '/admin/media/installations',
          token: token,
          queryParameters: const {'limit': '10'},
        ),
        {'installations', 'nextBefore'},
      );
      final raw = response['installations'];
      if (raw is! List || raw.length > 10 || response['nextBefore'] != null) {
        throw const FormatException();
      }
      final ids = <String>{};
      final matches = <({String installationId, int installationRevision})>[];
      for (final value in raw) {
        final target = _installation(value);
        if (!ids.add(target.installationId)) throw const FormatException();
        if (target.isReadyJellyfin) {
          matches.add((
            installationId: target.installationId,
            installationRevision: target.installationRevision,
          ));
        }
      }
      if (matches.length != 1) throw const FormatException();
      return matches.single;
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<ServerMediaCatalogPage> searchCurrent({
    required String query,
    ServerMediaCatalogKind? mediaKind,
    int offset = 0,
    int limit = 24,
    ServerMediaCatalogPage? previousPage,
  }) async {
    if ((offset == 0) != (previousPage == null) ||
        previousPage != null && previousPage.nextOffset != offset) {
      throw const LarenorServerException('invalid_request');
    }
    final target = await _discoverTarget();
    if (previousPage != null &&
        (target.installationId != previousPage.installationId ||
            target.installationRevision != previousPage.installationRevision)) {
      throw const LarenorServerException('invalid_response');
    }
    final page = await search(
      installationId: target.installationId,
      expectedInstallationRevision: target.installationRevision,
      query: query,
      mediaKind: mediaKind,
      offset: offset,
      limit: limit,
    );
    if (previousPage != null &&
        (page.snapshotRevision != previousPage.snapshotRevision ||
            page.jellyfinServiceRevision !=
                previousPage.jellyfinServiceRevision)) {
      throw const LarenorServerException('invalid_response');
    }
    return page;
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

  static ({
    String installationId,
    int installationRevision,
    bool isReadyJellyfin,
  })
  _installation(Object? value) {
    final item = _object(value, {
      'id',
      'requestId',
      'preparationId',
      'inspectionId',
      'serviceId',
      'operationId',
      'revision',
      'state',
      'phase',
      'cancelRequested',
      'installAvailable',
      'steps',
      'errorCode',
      'createdAt',
      'updatedAt',
    });
    final id = _id(item['id']);
    for (final field in [
      'requestId',
      'preparationId',
      'inspectionId',
      'operationId',
    ]) {
      _id(item[field]);
    }
    final revision = item['revision'];
    final service = item['serviceId'];
    final state = item['state'];
    final phase = item['phase'];
    final cancelled = item['cancelRequested'];
    final error = item['errorCode'];
    final steps = item['steps'];
    if (revision is! int ||
        revision < 1 ||
        revision > 0x7ffffffffffffffe ||
        !{'jellyfin', 'seerr', 'music_assistant'}.contains(service) ||
        !{
          'queued',
          'running',
          'container_started',
          'needs_attention',
          'failed',
          'cancelled',
        }.contains(state) ||
        !{'queued', 'executing', 'complete'}.contains(phase) ||
        cancelled is! bool ||
        item['installAvailable'] != false ||
        !(error == null ||
            {
              'authority_changed',
              'context_changed',
              'preparation_changed',
              'inspection_changed',
              'catalog_changed',
              'worker_unavailable',
              'invalid_worker_result',
              'resource_conflict',
              'dispatch_expired',
              'container_not_running',
            }.contains(error)) ||
        steps is! List ||
        steps.length != 2 ||
        !_timestamp(item['createdAt']) ||
        !_timestamp(item['updatedAt'])) {
      throw const FormatException();
    }
    for (var index = 0; index < steps.length; index++) {
      final step = _object(steps[index], {'stepId', 'kind'});
      _id(step['stepId']);
      if (step['kind'] != ['create_container', 'start_container'][index]) {
        throw const FormatException();
      }
    }
    final coherent = switch (state) {
      'queued' => phase == 'queued' && revision == 1 && !cancelled,
      'running' => phase == 'executing' && revision >= 2,
      _ => phase == 'complete' && revision >= 2,
    };
    final errorCoherent = switch (state) {
      'queued' ||
      'running' ||
      'container_started' ||
      'cancelled' => error == null,
      'needs_attention' || 'failed' => error != null,
      _ => false,
    };
    if (!coherent || !errorCoherent || state == 'cancelled' && !cancelled) {
      throw const FormatException();
    }
    return (
      installationId: id,
      installationRevision: revision,
      isReadyJellyfin:
          service == 'jellyfin' &&
          state == 'container_started' &&
          phase == 'complete' &&
          !cancelled &&
          error == null,
    );
  }

  static String _id(Object? value) {
    if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const FormatException();
    }
    return value;
  }

  static bool _timestamp(Object? value) {
    if (value is! String || value.length > 40 || value != value.trim()) {
      return false;
    }
    final parsed = DateTime.tryParse(value);
    return parsed != null && parsed.isUtc;
  }
}
