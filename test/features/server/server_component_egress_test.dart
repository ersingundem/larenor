import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/component_egress/data/server_component_egress_api.dart';
import 'package:larenor/features/server/component_egress/data/server_component_egress_controller.dart';
import 'package:larenor/features/server/component_egress/domain/server_component_egress_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/services/domain/server_service_models.dart';

import 'server_admin_test_support.dart';

const _serviceId = 'dddddddddddddddddddddddddddddddd';

Map<String, dynamic> _serviceJson({int revision = 4}) => {
  'id': _serviceId,
  'name': 'Home Assistant',
  'kind': 'home_assistant',
  'baseUrl': 'https://ha.example.test',
  'revision': revision,
  'credentialKeys': ['token'],
  'verification': {'state': 'never', 'checkedAt': null, 'version': null},
};

Map<String, dynamic> _grantJson() => {
  'scheme': 'https',
  'host': 'ha.example.test',
  'port': 443,
  'addresses': [
    {'address': '192.168.1.150', 'network': 'lan'},
  ],
};

Map<String, dynamic> _eventJson({int policyRevision = 1}) => {
  'actorId': adminId,
  'serviceId': _serviceId,
  'serviceRevision': 4,
  'correlationId': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
  'policyRevision': policyRevision,
  'source': 'core_api',
  'reason': 'policy_replaced',
  'command': 'replace_egress_policy',
  'result': 'accepted',
  'timestamp': 1788598800.25,
};

Map<String, dynamic> _responseJson({
  int policyRevision = 0,
  List<Map<String, dynamic>> grants = const [],
}) => {
  'schemaVersion': 2,
  'policy': {
    'component': 'home_assistant_probe',
    'serviceId': _serviceId,
    'serviceRevision': 4,
    'revision': policyRevision,
    'grants': grants,
  },
  'audit': policyRevision == 0
      ? <Map<String, dynamic>>[]
      : [_eventJson(policyRevision: policyRevision)],
};

class _EgressFixture extends AdminFixture {
  _EgressFixture() {
    respond = (request) async => policyResponse(request);
  }

  var revision = 0;
  List<Map<String, dynamic>> grants = [];

  http.Response policyResponse(http.Request request) {
    if (request.url.path.endsWith('/context')) return defaultResponse(request);
    if (request.method == 'GET') {
      return this.json(_responseJson(policyRevision: revision, grants: grants));
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (body['expectedRevision'] != revision ||
        body['expectedServiceRevision'] != 4) {
      return this.json({
        'error': {'code': 'revision_conflict'},
      }, 409);
    }
    revision++;
    grants = (body['grants'] as List)
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
    return this.json(_responseJson(policyRevision: revision, grants: grants));
  }
}

void main() {
  test('policy response is exact, bounded, attributed and redacted', () {
    final response = ServerComponentEgressResponse.fromJson(
      _responseJson(policyRevision: 1, grants: [_grantJson()]),
    );
    expect(
      response.policy.component,
      ServerComponentEgressComponent.homeAssistantProbe,
    );
    expect(
      response.policy.grants.single.addresses.single.network,
      ServerEgressNetwork.lan,
    );
    expect(response.toString(), isNot(contains('192.168')));
    expect(response.toString(), isNot(contains('ha.example')));

    final invalid = <Map<String, dynamic>>[
      {..._responseJson(), 'token': 'synthetic-secret'},
      {..._responseJson(), 'schemaVersion': 1},
      {
        ..._responseJson(policyRevision: 1, grants: [_grantJson()]),
        'policy': {
          ...(_responseJson(policyRevision: 1, grants: [_grantJson()])['policy']
              as Map),
          'grants': [
            {
              ..._grantJson(),
              'addresses': [
                {'address': '192.168.1.150', 'network': 'lan'},
                {'address': '192.168.1.150', 'network': 'lan'},
              ],
            },
          ],
        },
      },
      {
        ..._responseJson(policyRevision: 1, grants: [_grantJson()]),
        'policy': {
          ...(_responseJson(policyRevision: 1, grants: [_grantJson()])['policy']
              as Map),
          'grants': [
            {
              ..._grantJson(),
              'addresses': [
                {'address': '192.168.1.150', 'network': 'public'},
              ],
            },
          ],
        },
      },
      {
        ..._responseJson(policyRevision: 1),
        'audit': [
          {..._eventJson(), 'result': 'verified'},
        ],
      },
      {
        ..._responseJson(policyRevision: 1),
        'audit': [
          {..._eventJson(), 'serviceId': 'f' * 32},
        ],
      },
    ];
    for (final value in invalid) {
      expect(
        () => ServerComponentEgressResponse.fromJson(value),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });

  test(
    'API binds exact service revisions and verifies mutation readback',
    () async {
      final fixture = _EgressFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final service = ServerService.fromJson(_serviceJson());
      await fixture.account.withSession((raw, session) async {
        final api = ServerComponentEgressApi(raw, session.accessToken);
        final initial = await api.read(service);
        expect(initial.policy.revision, 0);
        final grant = ServerComponentEgressGrant.fromJson(_grantJson());
        final updated = await api.replace(service, initial, grant: grant);
        expect(updated.policy.revision, 1);
        expect(updated.policy.grants, [grant]);
        final request = fixture.mutations.single;
        expect(
          request.url.path,
          '/prefix/api/v1/admin/services/$_serviceId/outbound-policy',
        );
        expect(jsonDecode(request.body), {
          'expectedRevision': 0,
          'expectedServiceRevision': 4,
          'grants': [_grantJson()],
        });
        expect(request.body, isNot(contains('token')));
      });
    },
  );

  test('unsupported services never issue an outbound-policy request', () async {
    final fixture = _EgressFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await fixture.account.withSession((raw, session) async {
      final api = ServerComponentEgressApi(raw, session.accessToken);
      final unsupported = ServerService.fromJson({
        ..._serviceJson(),
        'kind': 'jellyfin',
      });
      await expectLater(
        api.read(unsupported),
        throwsA(isA<LarenorServerException>()),
      );
    });
    expect(fixture.adminCalls, isEmpty);
  });

  test('uncertain mutation requires refresh and never retries', () async {
    final fixture = _EgressFixture();
    await fixture.account.initialize();
    final controller = ServerComponentEgressController(
      fixture.account,
      ServerService.fromJson(_serviceJson()),
    );
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    await controller.load(current: () => true);
    final grant = ServerComponentEgressGrant.fromJson(_grantJson());
    fixture.revision = 2;
    await controller.replace(grant: grant, current: () => true);
    expect(controller.failure, 'revision_conflict');
    expect(controller.needsRefresh, isTrue);
    expect(controller.value, isNull);
    final count = fixture.mutations.length;
    await controller.replace(grant: grant, current: () => true);
    expect(fixture.mutations.length, count);
    await controller.load(current: () => true);
    expect(controller.needsRefresh, isFalse);
  });

  test('route loss and logout discard late policy results', () async {
    for (final logout in [false, true]) {
      final fixture = _EgressFixture();
      await fixture.account.initialize();
      final controller = ServerComponentEgressController(
        fixture.account,
        ServerService.fromJson(_serviceJson()),
      );
      final pending = Completer<http.Response>();
      fixture.respond = (_) => pending.future;
      var current = true;
      final load = controller.load(current: () => current);
      await Future<void>.delayed(Duration.zero);
      if (logout) {
        await fixture.account.signOut();
      } else {
        current = false;
        controller.invalidate();
      }
      pending.complete(fixture.json(_responseJson()));
      await load;
      expect(controller.value, isNull);
      controller.dispose();
      fixture.account.dispose();
    }
  });
}
