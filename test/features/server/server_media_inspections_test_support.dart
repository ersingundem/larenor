import 'dart:convert';

import 'package:http/http.dart' as http;

import 'server_media_preparations_test_support.dart';

Map<String, dynamic> mediaInspectionJson({
  String state = 'queued',
  int? revision,
  int index = 1,
}) {
  final preparation = mediaPreparationJson();
  final plan = preparation['plan'];
  return {
    'id': index.toRadixString(16).padLeft(32, '0'),
    'requestId': '2' * 32,
    'preparationId': preparation['id'],
    'preparationRevision': 1,
    'coreId': plan['coreId'],
    'homeId': plan['homeId'],
    'catalogDigest': plan['catalogDigest'],
    'planHash': plan['planHash'],
    'platform': plan['platform'],
    'revision': revision ?? (state == 'queued' ? 1 : 2),
    'state': state,
    'phase': state == 'queued'
        ? 'queued'
        : state == 'running'
        ? 'checking_requirements'
        : 'complete',
    'cancelRequested': state == 'cancelled',
    'createdAt': '2026-09-05T09:00:00.000Z',
    'updatedAt': '2026-09-05T09:00:01.000Z',
    'result': state != 'succeeded'
        ? null
        : {
            'catalogDigest': plan['catalogDigest'],
            'planHash': plan['planHash'],
            'platform': plan['platform'],
            'checkedAt': '2026-09-05T09:00:00.000Z',
            'checks': [
              for (final code in [
                'storage_root',
                'storage_capacity',
                'docker_engine',
                'daemon_mount_context',
                'daemon_network_context',
                'daemon_root_context',
                'port_availability',
                'receiver_network',
              ])
                {
                  'code': code,
                  'status':
                      code.startsWith('storage_') || code == 'docker_engine'
                      ? 'passed'
                      : 'unknown',
                  'rootId': null,
                  'availableMiB': null,
                  'requiredMiB': null,
                },
            ],
          },
    'errorCode': state == 'failed'
        ? 'worker_unavailable'
        : state == 'needs_attention'
        ? 'preparation_changed'
        : null,
  };
}

class MediaInspectionsFixture extends MediaPreparationsFixture {
  MediaInspectionsFixture({super.role, super.mustChange}) {
    records.add(mediaPreparationJson());
  }
  bool configured = true;
  final inspections = <Map<String, dynamic>>[];
  @override
  http.Response pluginResponse(http.Request request) {
    final path = request.url.path;
    if (path.endsWith('/media/inspections/capabilities')) {
      return this.json({
        'inspectionConfigured': configured,
        'installAvailable': false,
      });
    }
    if (path.endsWith('/media/inspections')) {
      if (request.method == 'GET') {
        final before = int.tryParse(
          request.url.queryParameters['before'] ?? '',
        );
        final rows =
            inspections
                .where(
                  (r) =>
                      before == null || int.parse(r['id'], radix: 16) < before,
                )
                .toList()
              ..sort(
                (a, b) => (b['id'] as String).compareTo(a['id'] as String),
              );
        final page = rows.take(10).toList();
        return this.json({
          'inspections': page,
          'nextBefore': rows.length > 10
              ? int.parse(page.last['id'], radix: 16)
              : null,
        });
      }
      final body = jsonDecode(request.body);
      final previous = inspections.where(
        (r) => r['requestId'] == body['requestId'],
      );
      if (previous.isNotEmpty)
        return this.json({'inspection': previous.first}, 201);
      final record = mediaInspectionJson(index: inspections.length + 1)
        ..['requestId'] = body['requestId'];
      inspections.add(record);
      return this.json({'inspection': record}, 201);
    }
    if (path.contains('/media/inspections/')) {
      final parts = path.split('/');
      final id = parts[parts.length - (path.endsWith('/cancel') ? 2 : 1)];
      final index = inspections.indexWhere((r) => r['id'] == id);
      if (index < 0)
        return this.json({
          'error': {'code': 'not_found'},
        }, 404);
      var record = inspections[index];
      if (path.endsWith('/cancel')) {
        if (jsonDecode(request.body)['expectedRevision'] !=
            record['revision']) {
          return this.json({
            'error': {'code': 'revision_conflict'},
          }, 409);
        }
        record = {
          ...record,
          'revision': record['revision'] + 1,
          'cancelRequested': true,
        };
        if (record['state'] == 'queued') {
          record['state'] = 'cancelled';
          record['phase'] = 'complete';
        }
        inspections[index] = record;
      }
      return this.json({'inspection': record});
    }
    return super.pluginResponse(request);
  }
}
