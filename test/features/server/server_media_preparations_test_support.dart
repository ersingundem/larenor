import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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
