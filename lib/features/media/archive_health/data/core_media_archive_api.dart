import 'dart:math';

import '../../../server/data/larenor_server_api.dart';
import '../../../server/domain/server_models.dart';
import '../domain/media_archive_health.dart';

final class CoreMediaArchiveApi {
  CoreMediaArchiveApi(this.api, this.token, {String Function()? requestId})
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

  Future<MediaArchiveHealthSnapshot> read() async {
    try {
      final target = await _target();
      final request = _requestId();
      _id(request);
      final authority = _object(
        await api.request(
          'POST',
          '/admin/media/archive-health/authority',
          token: token,
          body: {
            'requestId': request,
            'installationId': target.id,
            'expectedInstallationRevision': target.revision,
          },
        ),
        {
          'requestId',
          'installationId',
          'installationRevision',
          'snapshotRevision',
        },
      );
      final snapshotRevision = _positive(authority['snapshotRevision']);
      if (authority['requestId'] != request ||
          authority['installationId'] != target.id ||
          authority['installationRevision'] != target.revision) {
        throw const LarenorServerException('invalid_response');
      }
      final response = _object(
        await api.request(
          'POST',
          '/admin/media/archive-health/read',
          token: token,
          body: {
            'requestId': request,
            'installationId': target.id,
            'expectedInstallationRevision': target.revision,
            'expectedSnapshotRevision': snapshotRevision,
          },
        ),
        {'requestId', 'archive'},
      );
      final snapshot = MediaArchiveHealthSnapshot.fromJson(response['archive']);
      if (response['requestId'] != request ||
          snapshot.installationId != target.id ||
          snapshot.installationRevision != target.revision ||
          snapshot.snapshotRevision != snapshotRevision) {
        throw const LarenorServerException('invalid_response');
      }
      return snapshot;
    } on MediaArchiveReadException {
      rethrow;
    } on LarenorServerException catch (error) {
      throw MediaArchiveReadException(_kind(error.code));
    } catch (_) {
      throw const MediaArchiveReadException('unsupported');
    }
  }

  Future<({String id, int revision})> _target() async {
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
      throw const MediaArchiveReadException('unsupported');
    }
    final matches = <({String id, int revision})>[];
    final ids = <String>{};
    for (final value in raw) {
      final item = _installation(value);
      if (!ids.add(item.id)) {
        throw const LarenorServerException('invalid_response');
      }
      if (item.service == 'jellyfin' && item.ready) {
        matches.add((id: item.id, revision: item.revision));
      }
    }
    if (matches.length != 1) {
      throw const MediaArchiveReadException('unsupported');
    }
    return matches.single;
  }

  static String _kind(String code) => switch (code) {
    'unauthorized' || 'forbidden' || 'password_change_required' => 'forbidden',
    'media_archive_snapshot_stale' ||
    'media_archive_authority_changed' ||
    'media_installation_changed' ||
    'revision_conflict' => 'media_archive_snapshot_stale',
    'media_archive_worker_unavailable' ||
    'connection_failed' ||
    'timeout' ||
    'server_error' => 'connection_failed',
    _ => 'unsupported',
  };

  static Map<String, dynamic> _object(Object? value, Set<String> keys) {
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !value.keys.every(keys.contains)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  static String _id(Object? value) {
    if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  static int _positive(Object? value) {
    if (value is! int || value < 1 || value > 0x7fffffffffffffff) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  static ({String id, int revision, String service, bool ready}) _installation(
    Object? value,
  ) {
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
    final service = item['serviceId'];
    final state = item['state'];
    final phase = item['phase'];
    final cancelled = item['cancelRequested'];
    final error = item['errorCode'];
    if (!{'jellyfin', 'seerr', 'music_assistant'}.contains(service) ||
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
            }.contains(error))) {
      throw const LarenorServerException('invalid_response');
    }
    final steps = item['steps'];
    if (steps is! List || steps.length != 2) {
      throw const LarenorServerException('invalid_response');
    }
    for (var index = 0; index < steps.length; index++) {
      final step = _object(steps[index], {'stepId', 'kind'});
      _id(step['stepId']);
      if (step['kind'] != ['create_container', 'start_container'][index]) {
        throw const LarenorServerException('invalid_response');
      }
    }
    DateTime timestamp(Object? value) {
      if (value is! String || value.length != 24) {
        throw const LarenorServerException('invalid_response');
      }
      final parsed = DateTime.tryParse(value);
      if (parsed == null || parsed.toUtc().toIso8601String() != value) {
        throw const LarenorServerException('invalid_response');
      }
      return parsed;
    }

    final created = timestamp(item['createdAt']);
    final updated = timestamp(item['updatedAt']);
    final revision = _positive(item['revision']);
    if (updated.isBefore(created) ||
        state == 'queued' &&
            (phase != 'queued' || revision != 1 || cancelled) ||
        state == 'running' && phase != 'executing' ||
        !{'queued', 'running'}.contains(state) && phase != 'complete' ||
        {
              'queued',
              'running',
              'container_started',
              'cancelled',
            }.contains(state) &&
            error != null ||
        {'needs_attention', 'failed'}.contains(state) && error == null ||
        state == 'cancelled' && !cancelled) {
      throw const LarenorServerException('invalid_response');
    }
    return (
      id: id,
      revision: revision,
      service: service as String,
      ready:
          state == 'container_started' &&
          phase == 'complete' &&
          !cancelled &&
          error == null,
    );
  }

  @override
  String toString() => 'CoreMediaArchiveApi';
}
