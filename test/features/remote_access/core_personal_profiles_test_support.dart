import 'dart:convert' as convert;

import 'package:http/http.dart' as http;

import '../server/server_admin_test_support.dart';

const profileId = 'dddddddddddddddddddddddddddddddd';

Map<String, dynamic> profileJson({
  int revision = 1,
  String home = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  String label = 'Living room desktop',
}) => {
  'ref': {
    'schemaVersion': 1,
    'coreId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'homeId': home,
    'kind': 'remoteProfile',
    'id': profileId,
  },
  'revision': revision,
  'label': label,
  'protocol': 'ssh',
  'host': 'desk.internal.example',
  'port': 22,
  'username': 'private-user',
};

Map<String, dynamic> listJson(Map<String, dynamic> profile) => {
  'scope': {
    'schemaVersion': 1,
    'coreId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'homeId': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  },
  'collectionRevision': profile['revision'],
  'profiles': [profile],
};

class CoreProfilesFixture extends AdminFixture {
  CoreProfilesFixture() {
    record = profileJson();
    respond = response;
  }

  late Map<String, dynamic> record;
  bool offline = false, conflict = false;

  Future<http.Response> response(http.Request request) async {
    if (request.url.path.endsWith('/context')) return defaultResponse(request);
    if (!request.url.path.contains('/personal-profiles/')) {
      return defaultResponse(request);
    }
    if (offline) throw StateError('offline-marker-must-not-escape');
    if (request.method == 'GET') return json(listJson(record));
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : convert.jsonDecode(request.body) as Map<String, dynamic>;
    if (conflict ||
        request.method == 'PATCH' &&
            body['expectedRevision'] != record['revision'] ||
        request.method == 'DELETE' &&
            request.url.queryParameters['expectedRevision'] !=
                '${record['revision']}') {
      return json({
        'error': {'code': 'revision_conflict'},
      }, 409);
    }
    if (request.method == 'DELETE') return http.Response('', 204);
    final changed =
        request.method == 'POST' ||
        record['label'] != body['label'] ||
        record['protocol'] != body['protocol'] ||
        record['host'] != body['host'] ||
        record['port'] != body['port'] ||
        record['username'] != body['username'];
    record = {
      ...record,
      'revision': request.method == 'POST'
          ? 1
          : (record['revision'] as int) + (changed ? 1 : 0),
      'label': body['label'],
      'protocol': body['protocol'],
      'host': body['host'],
      'port': body['port'],
      'username': body['username'],
    };
    return json({'profile': record}, request.method == 'POST' ? 201 : 200);
  }
}
