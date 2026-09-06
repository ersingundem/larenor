import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/home_resources/data/home_resource_admin_api.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/home_resources/domain/home_resource_mutations.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

Map<String, dynamic> initialRecord() {
  final fixture = jsonDecode(File('contracts/home-resources.v1.json').readAsStringSync()) as Map;
  return {...fixture['adminList']['entries'][0] as Map<String, dynamic>, 'aclRevision': 1};
}

final scope = ServerContext.fromJson({'schemaVersion': 1, 'coreId': 'a' * 32, 'homeId': 'b' * 32});
final otherScope = ServerContext.fromJson({'schemaVersion': 1, 'coreId': 'c' * 32, 'homeId': 'd' * 32});
String get basePath => '/admin/home-resources/${scope.coreId}/${scope.homeId}';
HomeResourceRecord parsed(Map<String, dynamic> record) => HomeResourceRecord.fromJson(record, expectedContext: scope);
http.Response response(Object? data, [int status = 200]) => http.Response(jsonEncode(data), status, headers: {'content-type': 'application/json'});
Matcher failure(String code) => isA<LarenorServerException>().having((e) => e.code, 'static code', code);

void main() {
  test('versioned real FastAPI fixture matches the complete Client mutation sequence', () async {
    final fixture = jsonDecode(File('contracts/home-resource-admin.v1.json').readAsStringSync()) as Map;
    final currentScope = ServerContext.fromJson(fixture['context']);
    final steps = ['createRoom', 'createResource', 'updateRoom', 'noopRoom', 'deleteRoom'];
    var index = 0;
    final client = LarenorServerApi(endpoint: ServerEndpoint('https://synthetic.invalid'), client: MockClient((request) async {
      final step = fixture[steps[index++]];
      expect(request.method, step['method']);
      expect(request.url.path, '/api/v1${step['path']}');
      expect(request.url.queryParameters, step['query'] ?? <String,String>{});
      expect(request.body.isEmpty ? null : jsonDecode(request.body), step['body']);
      return step['status'] == 204 ? http.Response('', 204) : response(step['response'], step['status'] as int);
    }));
    addTearDown(client.close);
    final api = HomeResourceAdminApi(client, 'synthetic-token', currentScope);
    for(final name in ['createRoom', 'createResource']) {
      final step = fixture[name]; final body = step['body'];
      final record = await api.create(kind: HomeResourceKind.values.byName(body['kind'] as String), label: body['label'] as String, order: body['order'] as int);
      expect(record.id, step['response']['record']['ref']['id']);
    }
    var target = HomeResourceRecord.fromJson(fixture['beforeUpdate']['record'], expectedContext: currentScope);
    for(final name in ['updateRoom', 'noopRoom']) {
      final body = fixture[name]['body'];
      target = await api.update(target, label: body['label'] as String, order: body['order'] as int);
      expect(target.revision, fixture[name]['response']['record']['revision']);
      expect(target.aclRevision, 2);
    }
    await api.delete(target);
    expect(index, steps.length);
  });
  for (final label in ['', ' ', 'x' * 81, '\u0000x', 'x\n', '\u007f', '\ud800', '\udfff', '\u0085\u3000']) {
    test('invalid metadata label ${label.codeUnits} is rejected without transport', () async {
      var calls = 0;
      final client = LarenorServerApi(endpoint: ServerEndpoint('https://synthetic.invalid'), client: MockClient((_) async {calls++; return response({'record': initialRecord()});}));
      addTearDown(client.close);
      final api = HomeResourceAdminApi(client, 'synthetic-token', scope);
      await expectLater(api.create(kind: HomeResourceKind.room, label: label, order: 0), throwsA(failure('invalid_request')));
      await expectLater(api.update(parsed(initialRecord()), label: label, order: 0), throwsA(failure('invalid_request')));
      expect(calls, 0);
    });
  }
  for (final order in [-1, 10001]) {
    test('invalid order $order is rejected before transport', () async {
      var calls = 0;
      final client = LarenorServerApi(endpoint: ServerEndpoint('https://synthetic.invalid'), client: MockClient((_) async {calls++; return response(null);}));
      addTearDown(client.close);
      final api = HomeResourceAdminApi(client, 'synthetic-token', scope);
      await expectLater(api.create(kind: HomeResourceKind.room, label: 'Room', order: order), throwsA(failure('invalid_request')));
      await expectLater(api.update(parsed(initialRecord()), label: 'Room', order: order), throwsA(failure('invalid_request')));
      expect(calls, 0);
    });
  }
  for (final pair in [('  Salon\u3000', 'Salon'), ('🌿' * 80, '🌿' * 80), ('\ufeff', '\ufeff'), ('İstanbul', 'İstanbul')]) {
    test('request label follows Server codepoint and strip contract ${pair.$2.runes.length}', () {
      final value = HomeResourceMetadata(label: pair.$1, order: 10000);
      expect(value.label, pair.$2);
      expect(value.toJson(), {'label': pair.$2, 'order': 10000});
      value.toJson()['label'] = 'mutated';
      expect(value.label, pair.$2);
      expect(value.toString(), 'HomeResourceMetadata');
    });
  }
  for (final kind in HomeResourceKind.values) {
    test('create ${kind.name} sends exact fields and binds generated identity', () async {
      final raw = initialRecord(); raw['ref'] = {...raw['ref'] as Map, 'kind': kind.name};
      var calls = 0;
      final client = LarenorServerApi(endpoint: ServerEndpoint('https://synthetic.invalid/prefix'), client: MockClient((request) async {
        calls++;
        expect(request.method, 'POST');
        expect(request.url.path, '/prefix/api/v1$basePath');
        expect(request.url.hasQuery, isFalse);
        expect(request.headers['authorization'], 'Bearer synthetic-token');
        expect(jsonDecode(request.body), {'kind': kind.name, 'label': 'Salon', 'order': 1});
        return response({'record': raw}, 201);
      }));
      addTearDown(client.close);
      final api = HomeResourceAdminApi(client, 'synthetic-token', scope);
      final result = await api.create(kind: kind, label: ' Salon ', order: 1);
      expect(result.id, raw['ref']['id']); expect(result.kind, kind);
      expect(result.revision, 1); expect(result.aclRevision, 1); expect(result.canWrite, isTrue);
      expect(calls, 1);
      expect(api.toString(), 'HomeResourceAdminApi');
    });
  }
  for (final changed in [false, true]) {
    test('update ${changed ? 'changed' : 'no-op'} binds both revisions without altering ACL', () async {
      final raw = initialRecord(); raw['aclRevision'] = 7;
      final before = parsed(raw);
      final label = changed ? 'Yeni oda' : before.label;
      final expected = {...raw, 'label': label, 'revision': changed ? 2 : 1};
      var calls = 0;
      final client = LarenorServerApi(endpoint: ServerEndpoint('https://synthetic.invalid'), client: MockClient((request) async {
        calls++; expect(request.method, 'PATCH');
        expect(request.url.path, '/api/v1$basePath/${before.id}');
        expect(jsonDecode(request.body), {'expectedRevision': 1, 'expectedAclRevision': 7, 'label': label, 'order': 1});
        return response({'record': expected});
      }));
      addTearDown(client.close);
      final result = await HomeResourceAdminApi(client, 'synthetic-token', scope).update(before, label: ' $label ', order: 1);
      expect(result.label, label); expect(result.revision, changed ? 2 : 1); expect(result.aclRevision, 7); expect(calls, 1);
    });
  }
  for(final mutation in ['id','kind','revision','aclRevision','label','order','permissions','extra']) {
    test('create rejects response $mutation outside the submitted contract', () async {
      final raw=initialRecord();
      switch(mutation) {
        case 'id': raw['ref']={...raw['ref'] as Map,'id':'not-an-id'};
        case 'kind': raw['ref']={...raw['ref'] as Map,'kind':'resource'};
        case 'revision': raw['revision']=2;
        case 'aclRevision': raw['aclRevision']=2;
        case 'label': raw['label']='Other';
        case 'order': raw['order']=0;
        case 'permissions': raw['permissions']={'read':true,'write':false};
      }
      var calls=0;
      final client=LarenorServerApi(endpoint:ServerEndpoint('https://synthetic.invalid'),client:MockClient((_) async {calls++;return response({'record':raw,if(mutation=='extra')'extra':'private'},201);}));
      addTearDown(client.close);
      await expectLater(HomeResourceAdminApi(client,'synthetic-token',scope).create(kind:HomeResourceKind.room,label:'Salon',order:1),throwsA(failure('invalid_response')));
      expect(calls,1);
    });
  }
  test('cross-context update/delete fail before any HTTP', () async {
    var calls = 0;
    final client = LarenorServerApi(endpoint: ServerEndpoint('https://synthetic.invalid'), client: MockClient((_) async {calls++; return response(null);}));
    addTearDown(client.close);
    final api = HomeResourceAdminApi(client, 'synthetic-token', otherScope);
    await expectLater(api.update(parsed(initialRecord()), label: 'X', order: 0), throwsA(failure('invalid_request')));
    await expectLater(api.delete(parsed(initialRecord())), throwsA(failure('invalid_request')));
    expect(calls, 0);
  });
  for (final mutation in ['extraEnvelope', 'wrongScope', 'wrongId', 'wrongKind', 'label', 'order', 'revision', 'aclRevision', 'readOnly', 'boolRevision']) {
    test('rejects update response $mutation without replay', () async {
      final raw = initialRecord(); final target = parsed(raw);
      final changed = {...raw, 'revision': 2, 'label': 'Renamed'};
      switch (mutation) {
        case 'wrongScope': changed['ref'] = {...raw['ref'] as Map, 'homeId': 'd' * 32};
        case 'wrongId': changed['ref'] = {...raw['ref'] as Map, 'id': 'e' * 32};
        case 'wrongKind': changed['ref'] = {...raw['ref'] as Map, 'kind': 'resource'};
        case 'label': changed['label'] = 'Unexpected';
        case 'order': changed['order'] = 5;
        case 'revision': changed['revision'] = 3;
        case 'aclRevision': changed['aclRevision'] = 2;
        case 'readOnly': changed['permissions'] = {'read': true, 'write': false};
        case 'boolRevision': changed['revision'] = true;
      }
      var calls = 0;
      final client = LarenorServerApi(endpoint: ServerEndpoint('https://synthetic.invalid'), client: MockClient((_) async {calls++; return response({'record': changed, if(mutation == 'extraEnvelope') 'secret': 'private-upstream'});}));
      addTearDown(client.close);
      await expectLater(HomeResourceAdminApi(client, 'synthetic-token', scope).update(target, label: 'Renamed', order: 1), throwsA(failure('invalid_response')));
      expect(calls, 1);
    });
  }
  for (final status in [401, 403, 404, 409, 500, 503]) {
    test('write error $status is static and never automatically retried', () async {
      var calls = 0;
      final client = LarenorServerApi(endpoint: ServerEndpoint('https://synthetic.invalid'), client: MockClient((_) async {calls++; return response({'error': {'code': status == 409 ? 'revision_conflict' : 'private-token', 'message': 'private-token'}}, status);}));
      addTearDown(client.close);
      await expectLater(HomeResourceAdminApi(client, 'synthetic-token', scope).create(kind: HomeResourceKind.room, label: 'Room', order: 0), throwsA(isA<LarenorServerException>().having((e) => e.toString().contains('private-token'), 'redacted', isFalse)));
      expect(calls, 1);
    });
  }
  for (final variant in ['204empty', '204body', '200null', '200empty', '200object', '202empty', '500error']) {
    test('delete only accepts actual 204 empty: $variant', () async {
      var calls = 0;
      final target = parsed(initialRecord());
      final client = LarenorServerApi(endpoint: ServerEndpoint('https://synthetic.invalid/prefix'), client: MockClient((request) async {
        calls++; expect(request.method, 'DELETE');
        expect(request.url.path, '/prefix/api/v1$basePath/${target.id}');
        expect(request.url.queryParameters, {'expectedRevision': '1', 'expectedAclRevision': '1'});
        expect(request.body, isEmpty);
        return switch(variant) {
          '204empty' => http.Response('', 204),
          '204body' => response({}, 204),
          '200null' => response(null),
          '200empty' => http.Response('', 200),
          '200object' => response({}),
          '202empty' => http.Response('', 202),
          _ => response({'error': {'code': 'private', 'message': 'private'}}, 500),
        };
      }));
      addTearDown(client.close);
      final operation = HomeResourceAdminApi(client, 'synthetic-token', scope).delete(target);
      if(variant == '204empty') {await operation;} else {await expectLater(operation, throwsA(isA<LarenorServerException>()));}
      expect(calls, 1);
    });
  }
  test('timeout/cancel never repeats a possibly applied write', () async {
    var calls = 0;
    final gate = Completer<http.Response>();
    final client = LarenorServerApi(endpoint: ServerEndpoint('https://synthetic.invalid'), client: MockClient((_) {calls++; return gate.future;}));
    final pending = HomeResourceAdminApi(client, 'synthetic-token', scope).create(kind: HomeResourceKind.room, label: 'Salon', order: 1);
    final expectation = expectLater(pending, throwsA(failure('cancelled')));
    await Future<void>.delayed(Duration.zero); client.close();
    await expectation; gate.complete(response({'record': initialRecord()}, 201));
    await Future<void>.delayed(Duration.zero); expect(calls, 1);
  });
}
