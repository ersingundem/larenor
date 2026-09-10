import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/core_proxmox/data/core_proxmox_api.dart';
import 'package:larenor/features/core_proxmox/domain/core_proxmox_models.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/services/domain/server_service_models.dart';

void main() {
  final f = jsonDecode(
    File('contracts/proxmox-resource.v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final context = ServerContext.fromJson(f['context']);
  final target = HomeResourceRecord.fromJson(
    f['resource'],
    expectedContext: context,
  );
  late List<http.Request> requests;
  late CoreProxmoxApi api;
  setUp(() {
    requests = [];
    Map<String, dynamic>? proposed;
    api = CoreProxmoxApi(
      LarenorServerApi(
        endpoint: ServerEndpoint('https://core.invalid/prefix'),
        client: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          Object? response;
          var status = 200;
          if (path.endsWith('/snapshot')) {
            response = {'snapshot': f['snapshot']};
          } else if (path.endsWith('/binding-preview')) {
            proposed = {...f['binding'] as Map, 'id': '7' * 32, 'revision': 3};
            response = {
              'preview': {
                ...f['preview'] as Map,
                'binding': proposed,
                'summary': f['summary'],
              },
            };
            status = 201;
          } else if (path.endsWith('/binding-confirm')) {
            response = {'binding': proposed};
            status = 201;
          } else if (path.endsWith('/binding')) {
            response = {'binding': f['binding']};
          } else if (path.endsWith('/services')) {
            response = {
              'services': [f['service']],
            };
          } else if (path.contains('/home-resources/')) {
            response = {'record': f['resource']};
          } else if (request.method == 'DELETE') {
            return http.Response('', 204);
          } else {
            throw StateError('unexpected request $request');
          }
          return http.Response(
            jsonEncode(response),
            status,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
      'a' * 43,
      target,
      isCurrent: () => true,
    );
  });

  test('member path fetches exact resource and read-only snapshot', () async {
    final record = await api.resource();
    final snapshot = await api.snapshot();
    expect(record.id, target.id);
    expect(snapshot.summary.guests, hasLength(2));
    expect(requests.map((r) => (r.method, r.url.path)), [
      (
        'GET',
        '/prefix/api/v1/home-resources/${context.coreId}/${context.homeId}/${target.id}',
      ),
      (
        'GET',
        '/prefix/api/v1/proxmox/${context.coreId}/${context.homeId}/resources/${target.id}/snapshot',
      ),
    ]);
    expect(
      requests.every((r) => r.headers['authorization'] == 'Bearer ${'a' * 43}'),
      isTrue,
    );
  });

  test(
    'admin preview confirm cancel sends exact revisions and no command',
    () async {
      final service = ServerService.fromJson(f['service']);
      final binding = await api.binding();
      final preview = await api.preview(service: service, existing: binding);
      expect(jsonDecode(requests.last.body), {
        'serviceId': service.id,
        'expectedServiceRevision': service.revision,
        'expectedRevision': target.revision,
        'expectedAclRevision': target.aclRevision,
        'expectedBindingId': binding!.id,
      });
      expect((await api.confirm(preview)).sameBinding(preview.binding), isTrue);
      await api.cancel(preview);
      expect(requests.map((r) => r.method), isNot(contains('PATCH')));
      expect(
        requests.map((r) => r.url.path).join(' '),
        isNot(contains('commands')),
      );
    },
  );

  test('late response and foreign service selection are rejected', () async {
    var current = true;
    final guarded = CoreProxmoxApi(
      LarenorServerApi(endpoint: ServerEndpoint('https://core.invalid')),
      'a' * 43,
      target,
      isCurrent: () => current,
    );
    guarded.retire();
    expect(guarded.snapshot, throwsA(isA<LarenorServerException>()));
    current = false;
    expect(
      () => api.preview(
        service: ServerService.fromJson({
          ...f['service'] as Map,
          'kind': 'jellyfin',
        }),
        existing: null,
      ),
      throwsA(isA<LarenorServerException>()),
    );
  });
}
