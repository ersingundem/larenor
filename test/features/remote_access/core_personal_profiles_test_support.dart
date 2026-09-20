import 'dart:async';
import 'dart:convert' as convert;

import 'package:http/http.dart' as http;

import '../server/server_admin_test_support.dart';

const profileId = 'dddddddddddddddddddddddddddddddd';
const profileFamilyId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const profileAccountId = adminId;

Map<String, dynamic> profileJson({
  int revision = 1,
  String home = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  String account = adminId,
  String label = 'Living room desktop',
}) => {
  'ref': {
    'schemaVersion': 1,
    'coreId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'homeId': home,
    'kind': 'coreRemoteProfile',
    'id': profileId,
    'accountId': account,
  },
  'revision': revision,
  'label': label,
  'protocol': 'ssh',
  'host': 'desk.internal.example',
  'port': 22,
  'username': 'private-user',
};

Map<String, dynamic> authorityJson({
  String home = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  String account = adminId,
  String family = profileFamilyId,
  int accountRevision = 1,
  int collectionRevision = 1,
}) => {
  'schemaVersion': 1,
  'coreId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'homeId': home,
  'accountId': account,
  'sessionFamilyId': family,
  'accountRevision': accountRevision,
  'collectionRevision': collectionRevision,
};

Map<String, dynamic> listJson(
  Map<String, dynamic> profile, {
  int? collectionRevision,
  String account = adminId,
  String family = profileFamilyId,
  int accountRevision = 1,
}) => {
  'authority': authorityJson(
    account: account,
    family: family,
    accountRevision: accountRevision,
    collectionRevision: collectionRevision ?? profile['revision'] as int,
  ),
  'profiles': [profile],
};

class CoreProfilesFixture extends AdminFixture {
  CoreProfilesFixture() {
    record = profileJson();
    respond = response;
  }

  late Map<String, dynamic> record;
  bool offline = false, conflict = false;
  bool losePatchResponse = false;
  int patchCalls = 0;
  int? collectionRevisionOverride;
  int? storedCollectionRevision;
  String familyId = profileFamilyId;
  int accountRevision = 1;
  Completer<void>? holdNextList;

  int get collectionRevision =>
      storedCollectionRevision ?? record['revision'] as int;

  Map<String, dynamic> authority([int? revision]) => authorityJson(
    family: familyId,
    accountRevision: accountRevision,
    collectionRevision: revision ?? collectionRevision,
  );

  Future<http.Response> response(http.Request request) async {
    if (request.url.path.endsWith('/context')) return defaultResponse(request);
    if (!request.url.path.contains('/core-remote-profiles/')) {
      return defaultResponse(request);
    }
    if (offline) throw StateError('offline-marker-must-not-escape');
    if (request.method == 'GET') {
      final held = holdNextList;
      holdNextList = null;
      if (held != null) await held.future;
      return json(
        listJson(
          record,
          collectionRevision: collectionRevisionOverride ?? collectionRevision,
          family: familyId,
          accountRevision: accountRevision,
        ),
      );
    }
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : convert.jsonDecode(request.body) as Map<String, dynamic>;
    final expectedCollection = request.method == 'DELETE'
        ? int.tryParse(
            request.url.queryParameters['expectedCollectionRevision'] ?? '',
          )
        : body['expectedCollectionRevision'];
    final expectedAccount = request.method == 'DELETE'
        ? int.tryParse(
            request.url.queryParameters['expectedAccountRevision'] ?? '',
          )
        : body['expectedAccountRevision'];
    final expectedRecord = request.method == 'DELETE'
        ? int.tryParse(request.url.queryParameters['expectedRevision'] ?? '')
        : body['expectedRevision'];
    final requestId = request.method == 'DELETE'
        ? request.url.queryParameters['requestId']
        : body['requestId'];
    if (requestId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      return json({
        'error': {'code': 'invalid_request'},
      }, 400);
    }
    if (conflict ||
        expectedAccount != accountRevision ||
        expectedCollection != collectionRevision ||
        request.method != 'POST' && expectedRecord != record['revision']) {
      return json({
        'error': {'code': 'revision_conflict'},
      }, 409);
    }
    final priorCollection = collectionRevision;
    if (request.method == 'DELETE') {
      final previous = record['revision'] as int;
      return json({
        'authority': authority(priorCollection + 1),
        'deletion': {'ref': record['ref'], 'deletedRevision': previous},
      });
    }
    if (request.method == 'PATCH') patchCalls++;
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
    final nextCollection = priorCollection + (changed ? 1 : 0);
    if (request.method == 'PATCH' && losePatchResponse) {
      losePatchResponse = false;
      storedCollectionRevision = nextCollection;
      throw StateError('lost-response-marker-must-not-escape');
    }
    storedCollectionRevision = nextCollection;
    return json({
      'authority': authority(nextCollection),
      'profile': record,
    }, request.method == 'POST' ? 201 : 200);
  }
}
