import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

import 'server_plugins_test_support.dart';

Map<String, dynamic> mediaFixtureJson() =>
    jsonDecode(File('contracts/media-preparations.v1.json').readAsStringSync())
        as Map<String, dynamic>;
Map<String, dynamic> mediaPreparationJson({bool cancelled = false}) =>
    mediaFixtureJson()[cancelled ? 'cancelled' : 'prepared']
        as Map<String, dynamic>;

class MediaPreparationsFixture extends PluginsFixture {
  MediaPreparationsFixture({super.role, super.mustChange});
  final records = <Map<String, dynamic>>[];
  @override
  http.Response pluginResponse(http.Request request) {
    final path = request.url.path;
    if (path.endsWith('/context'))
      return this.json(mediaFixtureJson()['context']);
    if (path.endsWith('/media/preparations')) {
      if (request.method == 'GET') {
        return this.json({'preparations': records, 'nextBefore': null});
      }
      final body = jsonDecode(request.body);
      final existing = records.where(
        (r) => r['requestId'] == body['requestId'],
      );
      if (existing.isNotEmpty)
        return this.json({'preparation': existing.first}, 201);
      final record = mediaPreparationJson()..['requestId'] = body['requestId'];
      records.add(record);
      return this.json({'preparation': record}, 201);
    }
    if (path.contains('/media/preparations/')) {
      final parts = path.split('/');
      final id = parts[parts.length - (path.endsWith('/cancel') ? 2 : 1)];
      final found = records.indexWhere((r) => r['id'] == id);
      if (found < 0)
        return this.json({
          'error': {'code': 'not_found'},
        }, 404);
      if (path.endsWith('/cancel')) {
        final previous = records[found];
        if (jsonDecode(request.body)['expectedRevision'] !=
            previous['revision']) {
          return this.json({
            'error': {'code': 'revision_conflict'},
          }, 409);
        }
        records[found] = mediaPreparationJson(cancelled: true)
          ..['requestId'] = previous['requestId'];
      }
      return this.json({'preparation': records[found]});
    }
    return super.pluginResponse(request);
  }
}

/// Distinct synthetic records for history paging, based on the real HTTP
/// fixture and the public deterministic identity/hash format.
Map<String, dynamic> pagedMediaPreparation(int index, {bool cancelled = true}) {
  final record = mediaPreparationJson(cancelled: cancelled);
  final id = index.toRadixString(16).padLeft(32, '0');
  record['id'] = id;
  record['requestId'] = (index + 256).toRadixString(16).padLeft(32, '0');
  final plan = record['plan'] as Map<String, dynamic>;
  plan['preparationId'] = id;
  String identity(String kind, String service, [String step = '']) => sha256.convert(utf8.encode(['larenor-media-stack-v1', kind, plan['coreId'], plan['homeId'], id, service, step].join('\u0000'))).toString().substring(0, 32);
  for (final component in plan['components']) {
    final service = component['serviceId'] as String;
    component['installationId'] = identity('installation', service);
    component['operationId'] = identity('operation', service);
    for (final step in component['steps']) { step['stepId'] = identity('step', service, step['kind']); }
  }
  Object? canonical(Object? value) {
    if (value is Map<String, dynamic>) {
      final keys = value.keys.toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }
  plan['planHash'] = sha256.convert(utf8.encode(jsonEncode(canonical({...plan}..remove('planHash'))))).toString();
  return record;
}
