import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/core_ha/data/core_ha_api.dart';
import 'package:larenor/features/core_ha/domain/core_ha_models.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/services/domain/server_service_models.dart';

import 'core_ha_models_test.dart';

Map<String, dynamic> serviceJson() => {'id': '5' * 32, 'name': 'Home service', 'kind': 'home_assistant', 'baseUrl': 'http://synthetic.invalid', 'revision': 1, 'credentialKeys': ['token'], 'verification': {'state': 'never', 'checkedAt': null, 'version': null}};
http.Response response(Object? value, [int status = 200]) => status == 204 ? http.Response('', 204) : http.Response(jsonEncode(value), status, headers: {'content-type': 'application/json'});

void main() {
  final prefix = '/home-assistant/${target().context.coreId}/${target().context.homeId}/resources/${target().id}';
  CoreHaApi create(Future<http.Response> Function(http.Request) handle, {bool Function()? current, HomeResourceRecord? record}) {
    final transport = LarenorServerApi(endpoint: ServerEndpoint('https://synthetic.invalid/prefix'), client: MockClient(handle));
    addTearDown(transport.close);
    return CoreHaApi(transport, 'fixture_token', record ?? target(), isCurrent: current ?? () => true);
  }
  test('read/binding protocol uses one bounded transport and exact requests', () async {
    final requests = <http.Request>[];
    final replies = [
      {'record': resourceJson()}, {'snapshot': snapshotJson()}, {'binding': bindingJson()}, {'services': [serviceJson()]}, {'preview': previewJson()}, {'binding': bindingJson()}, null,
    ];
    final api = create((request) async {
      requests.add(request);
      return response(replies[requests.length - 1], requests.length == 7 ? 204 : requests.length >= 5 ? 201 : 200);
    });
    expect((await api.resource()).id, target().id);
    expect((await api.snapshot()).projection.state, CoreHaSwitchState.off);
    expect((await api.binding())!.revision, 1);
    final services = await api.services();
    final preview = await api.preview(service: services.single, entityId: 'switch.reading_lamp', existing: null);
    expect((await api.confirm(preview)).sameBinding(preview.binding), isTrue);
    await api.cancel(preview);
    expect(requests.map((r) => r.method), ['GET', 'GET', 'GET', 'GET', 'POST', 'POST', 'DELETE']);
    expect(requests.map((r) => r.url.path), [
      '/prefix/api/v1/home-resources/${target().context.coreId}/${target().context.homeId}/${target().id}',
      '/prefix/api/v1$prefix/snapshot', '/prefix/api/v1/admin$prefix/binding', '/prefix/api/v1/admin/services',
      '/prefix/api/v1/admin$prefix/binding-preview', '/prefix/api/v1/admin$prefix/binding-confirm', '/prefix/api/v1/admin$prefix/binding-preview/${preview.id}',
    ]);
    expect(jsonDecode(requests[4].body), {'serviceId': services.single.id, 'expectedServiceRevision': 1, 'expectedRevision': 1, 'expectedAclRevision': 1, 'entityId': 'switch.reading_lamp', 'expectedBindingId': null});
    expect(jsonDecode(requests[5].body), {'previewId': preview.id});
    for (final request in requests) {
      expect(request.headers['authorization'], 'Bearer fixture_token');
      expect(request.followRedirects, isFalse); expect(request.url.queryParameters, isEmpty);
    }
  });
  test('binding404 is explicit absence and HA502 never becomes Core401', () async {
    var code = 'not_found', status = 404;
    final api = create((_) async => response({'error': {'code': code}}, status));
    expect(await api.binding(), isNull);
    code = 'ha_upstream_unauthorized'; status = 502;
    await expectLater(api.snapshot(), throwsA(failure(code)));
  });
  for (final status in [200, 401]) {
    test('retired late$status becomes cancelled and never revives', () async {
      final pending = Completer<http.Response>(); var current = true, calls = 0;
      final api = create((_) { calls++; return pending.future; }, current: () => current);
      final request = api.snapshot();
      final check = expectLater(request, throwsA(failure('cancelled')));
      await Future<void>.delayed(Duration.zero); current = false;
      pending.complete(response(status == 200 ? {'snapshot': snapshotJson()} : {'error': {'code': 'unauthorized'}}, status));
      await check; current = true;
      await expectLater(api.snapshot(), throwsA(failure('cancelled'))); expect(calls, 1);
    });
  }
  test('current401 is preserved for the shared account rejection boundary', () async {
    final api = create((_) async => response({'error': {'code': 'unauthorized'}}, 401));
    await expectLater(api.snapshot(), throwsA(failure('unauthorized')));
  });
  test('retirement and throwing owner prohibit any dispatch', () async {
    var calls = 0;
    final api = create((_) async { calls++; return response(null); });
    api.retire(); await expectLater(api.snapshot(), throwsA(failure('cancelled')));
    final throwing = create((_) async { calls++; return response(null); }, current: () => throw StateError('private'));
    await expectLater(throwing.resource(), throwsA(failure('cancelled'))); expect(calls, 0);
  });
  test('room and invalid entity prohibit any dispatch', () async {
    var calls = 0;
    Future<http.Response> handler(http.Request _) async { calls++; return response(null); }
    final room = HomeResourceRecord.fromJson({...resourceJson(), 'ref': {...refJson(), 'kind': 'room'}}, expectedContext: target().context);
    await expectLater(create(handler, record: room).snapshot(), throwsA(failure('invalid_request')));
    await expectLater(create(handler).preview(service: ServerService.fromJson(serviceJson()), entityId: 'light.lamp', existing: null), throwsA(failure('invalid_request')));
    expect(calls, 0);
  });
  test('preview validates exact proposed service/entity and successor', () async {
    var value = previewJson();
    final api = create((_) async => response({'preview': value}, 201));
    for (final entry in {'serviceId': '7' * 32, 'serviceRevision': 2, 'entityId': 'switch.other', 'revision': 2}.entries) {
      value = {...previewJson(), 'binding': {...bindingJson(), entry.key: entry.value}};
      await expectLater(api.preview(service: ServerService.fromJson(serviceJson()), entityId: 'switch.reading_lamp', existing: null), throwsA(failure('invalid_response')));
    }
  });
  test('rebind requires newID and revision successor; confirm exactly matches preview', () async {
    final old = CoreHaBinding.fromJson(bindingJson(), target: target());
    final successor = {...bindingJson(), 'id': '7' * 32, 'revision': 2};
    var value = <String, dynamic>{'preview': {...previewJson(), 'binding': successor}};
    final api = create((_) async => response(value, 201));
    final preview = await api.preview(service: ServerService.fromJson(serviceJson()), entityId: 'switch.reading_lamp', existing: old);
    value = {'binding': {...successor, 'id': '8' * 32}};
    await expectLater(api.confirm(preview), throwsA(failure('invalid_response')));
  });
  test('unknown envelope/raw data and oversized body fail closed', () async {
    var value = <String, dynamic>{'snapshot': snapshotJson(), 'rawAttributes': 'private'};
    final api = create((_) async => response(value));
    await expectLater(api.snapshot(), throwsA(failure('invalid_response')));
    value = {'snapshot': 'x' * 300000};
    await expectLater(api.snapshot(), throwsA(failure('invalid_response')));
  });
}
