import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/power_recovery/data/server_power_target_provisioning.dart';

const _coreId = '1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a';
const _homeId = '2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b';
const _actorId = '3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c';
const _resourceId = '44444444444444444444444444444444';
const _bindingId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _serviceId = 'cccccccccccccccccccccccccccccccc';

final _context = ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': _coreId,
  'homeId': _homeId,
});

Map<String, dynamic> _resourceJson() => {
  'ref': {
    'schemaVersion': 1,
    'coreId': _coreId,
    'homeId': _homeId,
    'kind': 'resource',
    'id': _resourceId,
  },
  'label': 'Media VM',
  'order': 10,
  'revision': 5,
  'aclRevision': 6,
  'permissions': {'read': true, 'write': true},
};

Map<String, dynamic> _resourcePage() => {
  'scope': _context.toJson(),
  'userRevision': 3,
  'entries': [_resourceJson()],
  'snapshot': 'a' * 64,
  'nextAfter': null,
};

Map<String, dynamic> _discoveryPage() => {
  'schemaVersion': 1,
  'scope': _context.toJson(),
  'resourceId': _resourceId,
  'userRevision': 3,
  'resourceRevision': 5,
  'aclRevision': 6,
  'bindingId': _bindingId,
  'bindingRevision': 7,
  'serviceId': _serviceId,
  'serviceRevision': 8,
  'snapshot': 'b' * 64,
  'targets': [
    {
      'schemaVersion': 1,
      'targetId': 'dddddddddddddddddddddddddddddddd',
      'installationId': _serviceId,
      'node': 'node-a',
      'guestKind': 'qemu',
      'guestId': 101,
      'currentState': 'running',
      'statusRevision': 9,
      'allowedCommands': ['shutdown', 'stop', 'reboot', 'reset', 'suspend'],
      'capabilityReady': true,
    },
  ],
  'nextAfter': null,
};

Map<String, dynamic> _egress({
  String component = 'proxmox_command_worker',
  int serviceRevision = 8,
  int revision = 10,
}) => {
  'schemaVersion': 2,
  'policy': {
    'component': component,
    'serviceId': _serviceId,
    'serviceRevision': serviceRevision,
    'revision': revision,
    'grants': [
      {
        'scheme': 'https',
        'host': 'proxmox.example.test',
        'port': 8006,
        'addresses': [
          {'address': '192.168.1.20', 'network': 'lan'},
        ],
      },
    ],
  },
  'audit': <Map<String, dynamic>>[],
};

http.Response _json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'provisions one exact read-only authority from verified server facts',
    () async {
      final requests = <http.Request>[];
      final transport = LarenorServerApi(
        endpoint: ServerEndpoint('https://core.invalid'),
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/home-resources/$_coreId/$_homeId')) {
            return _json(_resourcePage());
          }
          if (request.url.path.endsWith('/$_resourceId/targets')) {
            return _json(_discoveryPage());
          }
          if (request.url.path.endsWith('/$_serviceId/outbound-policy')) {
            return _json(_egress());
          }
          return _json({
            'error': {'code': 'not_found'},
          }, 404);
        }),
      );
      final api = ServerPowerTargetProvisioningApi(
        api: transport,
        token: 't' * 43,
        context: _context,
        actorId: _actorId,
      );

      final resources = await api.resources();
      final provider = await api.provision(resources.single);

      expect(provider.actorId, _actorId);
      expect(provider.actorRevision, 3);
      expect(provider.resourceRevision, 5);
      expect(provider.aclRevision, 6);
      expect(provider.bindingRevision, 7);
      expect(provider.serviceRevision, 8);
      expect(provider.egressRevision, 10);
      expect(provider.statusRevision, 9);
      expect(provider.targetId, '3733d87f3c38d2a0b48206926883d9b5');
      expect(requests.map((request) => request.method), ['GET', 'GET', 'GET']);
      expect(requests[0].url.queryParameters, {'limit': '100'});
      expect(requests[1].url.queryParameters, {'limit': '2'});
      expect(
        requests[2].url.path,
        '/api/v1/admin/services/$_serviceId/outbound-policy',
      );
      transport.close();
    },
  );

  test('changed egress authority never becomes a provider reference', () async {
    final resource = HomeResourceRecord.fromJson(
      _resourceJson(),
      expectedContext: _context,
    );
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.invalid'),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/$_resourceId/targets')) {
          return _json(_discoveryPage());
        }
        return _json(_egress(serviceRevision: 9));
      }),
    );
    final api = ServerPowerTargetProvisioningApi(
      api: transport,
      token: 't' * 43,
      context: _context,
      actorId: _actorId,
    );

    await expectLater(
      api.provision(resource),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'power_target_unavailable',
        ),
      ),
    );
    transport.close();
  });
}
