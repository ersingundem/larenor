import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/keenetic/core/data/core_keenetic_api.dart';
import 'package:larenor/features/keenetic/core/data/core_keenetic_dashboard_providers.dart';
import 'package:larenor/features/keenetic/core/domain/core_keenetic_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

Map<String, dynamic> scopeJson() => {
  'schemaVersion': 1,
  'coreId': '1' * 32,
  'homeId': '2' * 32,
};
Map<String, dynamic> refJson() => {
  ...scopeJson(),
  'kind': 'resource',
  'id': '3' * 32,
};
Map<String, dynamic> resourceJson() => {
  'ref': refJson(),
  'label': 'Router',
  'order': 1,
  'revision': 1,
  'aclRevision': 1,
  'permissions': {'read': true, 'write': true},
};
HomeResourceRecord target() => HomeResourceRecord.fromJson(
  resourceJson(),
  expectedContext: ServerContext.fromJson(scopeJson()),
);
Map<String, dynamic> telemetryJson() => {
  'status': {
    'online': true,
    'publicIp': '198.51.100.20',
    'uptimeSeconds': 86400,
    'firmware': '4.3.6',
    'cpuPercent': 17.5,
    'memoryPercent': 42.0,
  },
  'interfaces': [
    {
      'id': 'GigabitEthernet0',
      'name': 'Internet',
      'kind': 'wan',
      'online': true,
      'address': '192.0.2.2',
      'rxBytes': 1200,
      'txBytes': 500,
    },
  ],
  'traffic': {
    'rxBytes': 1200,
    'txBytes': 500,
    'downloadBps': 90,
    'uploadBps': 30,
  },
  'hosts': [
    {
      'id': 'host-1',
      'name': 'Tablet',
      'ipAddress': '192.0.2.20',
      'macAddress': '02:00:00:00:00:01',
      'interfaceId': 'GigabitEthernet0',
      'online': true,
      'registered': true,
    },
  ],
};
Map<String, dynamic> bindingJson() => {
  'id': '4' * 32,
  'revision': 1,
  'ref': refJson(),
  'serviceId': '5' * 32,
  'serviceRevision': 1,
};
Map<String, dynamic> snapshotJson() => {
  'ref': refJson(),
  'bindingId': '4' * 32,
  'bindingRevision': 1,
  'serviceId': '5' * 32,
  'serviceRevision': 1,
  'resourceRevision': 1,
  'aclRevision': 1,
  'observedAt': '2026-09-10T12:00:00Z',
  'remainingTtlMs': 5000,
  'telemetry': telemetryJson(),
};
Map<String, dynamic> previewJson() => {
  'id': '6' * 32,
  'expiresInMs': 60000,
  'binding': bindingJson(),
  'snapshot': telemetryJson(),
};
Map<String, dynamic> serviceJson() => {
  'id': '5' * 32,
  'name': 'Core router',
  'kind': 'keenetic',
  'baseUrl': 'https://router.invalid',
  'revision': 1,
  'credentialKeys': ['password', 'username'],
  'verification': {
    'state': 'authenticated',
    'checkedAt': '2026-09-10T12:00:00Z',
    'version': '4.3.6',
  },
};
http.Response response(Object? value, [int status = 200]) => status == 204
    ? http.Response('', 204)
    : http.Response(
        jsonEncode(value),
        status,
        headers: {'content-type': 'application/json'},
      );

void main() {
  test(
    'dashboard readback requires exact resource ACL and binding revisions',
    () {
      final tile = TileConfig(
        id: 'core-router',
        type: TileType.coreKeenetic,
        x: 0,
        y: 0,
        width: 3,
        height: 2,
        title: 'Router',
        coreId: '1' * 32,
        coreHomeId: '2' * 32,
        coreResourceId: '3' * 32,
        coreResourceRevision: 1,
        coreResourceAclRevision: 1,
        coreBindingId: '4' * 32,
        coreBindingRevision: 1,
      );
      final record = coreKeeneticTileTarget(
        tile,
        ServerContext.fromJson(scopeJson()),
      );
      final snapshot = CoreKeeneticSnapshot.fromJson(
        snapshotJson(),
        target: record,
      );
      validateCoreKeeneticDashboardReadback(tile, record, snapshot);
      for (final changed in [
        tile.copyWith(coreResourceRevision: 2),
        tile.copyWith(coreResourceAclRevision: 2),
        tile.copyWith(coreBindingId: '9' * 32),
        tile.copyWith(coreBindingRevision: 2),
      ]) {
        expect(
          () =>
              validateCoreKeeneticDashboardReadback(changed, record, snapshot),
          throwsA(
            isA<LarenorServerException>().having(
              (value) => value.code,
              'code',
              'resource_changed',
            ),
          ),
        );
      }
    },
  );

  test('strict telemetry preserves public IP and typed metrics', () {
    final value = CoreKeeneticTelemetry.fromJson(telemetryJson());
    expect(value.status.publicIp, '198.51.100.20');
    expect(value.status.cpuPercent, 17.5);
    expect(value.interfaces.single.kind, CoreKeeneticInterfaceKind.wan);
    expect(value.onlineHosts, 1);
    for (final invalid in [
      {...telemetryJson(), 'private': 'secret'},
      {
        ...telemetryJson(),
        'status': {...telemetryJson()['status'] as Map, 'online': 'yes'},
      },
      {...telemetryJson(), 'interfaces': []},
      {
        ...telemetryJson(),
        'status': {
          ...telemetryJson()['status'] as Map,
          'firmware': 'safe\u202Etxt',
        },
      },
    ]) {
      expect(
        () => CoreKeeneticTelemetry.fromJson(invalid),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });

  test('member snapshot and admin binding flow use exact Core paths', () async {
    final requests = <http.Request>[];
    final replies = [
      {'snapshot': snapshotJson()},
      {'binding': bindingJson()},
      {
        'services': [serviceJson()],
      },
      {'preview': previewJson()},
      {'binding': bindingJson()},
      null,
    ];
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.invalid/prefix'),
      client: MockClient((request) async {
        requests.add(request);
        return response(
          replies[requests.length - 1],
          requests.length == 6 ? 204 : 200,
        );
      }),
    );
    addTearDown(transport.close);
    final api = CoreKeeneticApi(
      transport,
      'fixture-token',
      target(),
      isCurrent: () => true,
    );
    expect((await api.snapshot()).telemetry.status.online, isTrue);
    expect((await api.binding())!.id, '4' * 32);
    final service = (await api.services()).single;
    final preview = await api.preview(service: service, existing: null);
    expect((await api.confirm(preview)).sameBinding(preview.binding), isTrue);
    await api.cancel(preview);
    expect(requests.map((r) => r.method), [
      'GET',
      'GET',
      'GET',
      'POST',
      'POST',
      'DELETE',
    ]);
    expect(jsonDecode(requests[3].body), {
      'serviceId': '5' * 32,
      'expectedServiceRevision': 1,
      'expectedResourceRevision': 1,
      'expectedAclRevision': 1,
      'expectedBindingId': null,
    });
    expect(
      requests.every(
        (r) => r.headers['authorization'] == 'Bearer fixture-token',
      ),
      isTrue,
    );
  });

  test('retired late response is cancelled and cannot reopen', () async {
    final pending = Completer<http.Response>();
    var current = true, calls = 0;
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.invalid'),
      client: MockClient((_) {
        calls++;
        return pending.future;
      }),
    );
    addTearDown(transport.close);
    final api = CoreKeeneticApi(
      transport,
      'fixture-token',
      target(),
      isCurrent: () => current,
    );
    final result = api.snapshot();
    current = false;
    pending.complete(response({'snapshot': snapshotJson()}));
    await expectLater(
      result,
      throwsA(
        isA<LarenorServerException>().having(
          (e) => e.code,
          'code',
          'cancelled',
        ),
      ),
    );
    current = true;
    await expectLater(api.snapshot(), throwsA(isA<LarenorServerException>()));
    expect(calls, 1);
  });
}
