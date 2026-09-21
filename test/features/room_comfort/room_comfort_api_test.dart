import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/room_comfort/data/room_comfort_api.dart';
import 'package:larenor/features/room_comfort/domain/room_comfort_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

ServerContext _context() => ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
});

ServerSession _session() => ServerSession(
  endpoint: ServerEndpoint('https://core.invalid'),
  accessToken: 'x' * 43,
  refreshToken: 'y' * 43,
  expiresAt: DateTime.utc(2026, 10),
  context: _context(),
  user: ServerUser(
    id: 'c' * 32,
    username: 'admin',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
);

Map<String, Object?> _plan() => {
  'schemaVersion': 1,
  'planId': 'd' * 32,
  ..._context().toJson(),
  'homeRevision': 1,
  'policyId': 'e' * 32,
  'policyRevision': 2,
  'policyHash': 'f' * 64,
  'actorAccountId': 'c' * 32,
  'accountRevision': 3,
  'sessionFamilyId': '1' * 32,
  'generatedAtMs': 1788609600000,
  'inputRevisions': {'bounded': true},
  'occupancyAdvisory': {'2' * 32: 'occupied'},
  'items': [
    {
      'schemaVersion': 1,
      'room': {
        'schemaVersion': 1,
        'coreId': 'a' * 32,
        'homeId': 'b' * 32,
        'roomId': '2' * 32,
        'roomRevision': 4,
        'areaId': '3' * 32,
        'areaRevision': 5,
        'hvac': <String, Object?>{},
        'window': <String, Object?>{},
      },
      'status': 'planned',
      'reason': 'temperature_low',
      'hvacMode': 'heat',
      'windowState': 'closed',
    },
  ],
};

Map<String, Object?> _preview() => {
  'schemaVersion': 1,
  'previewId': '4' * 32,
  'confirmToken': 'T' * 43,
  'requestId': '5' * 32,
  'planId': 'd' * 32,
  'expiresAtMs': DateTime.now()
      .toUtc()
      .add(const Duration(minutes: 1))
      .millisecondsSinceEpoch,
  'commandCount': 1,
};

Map<String, Object?> _receipt() => {
  'schemaVersion': 1,
  'requestId': '5' * 32,
  'planId': 'd' * 32,
  'status': 'unknown',
  'results': [
    {
      'schemaVersion': 1,
      'commandId': '6' * 32,
      'roomId': '2' * 32,
      'targetKind': 'hvac',
      'status': 'unknown',
      'code': 'worker_ack_unknown',
      'readback': null,
    },
  ],
  'completedAtMs': 1788609601000,
};

http.Response _json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'authenticated adapter binds plan preview and confirm to exact scope',
    () async {
      final requests = <http.Request>[];
      final transport = LarenorServerApi(
        endpoint: _session().endpoint,
        client: MockClient((request) async {
          requests.add(request);
          expect(request.headers['authorization'], 'Bearer ${'x' * 43}');
          if (request.method == 'GET') {
            return _json({'schemaVersion': 1, 'plan': _plan()});
          }
          if (request.url.path.endsWith('/previews')) {
            return _json({'schemaVersion': 1, 'preview': _preview()}, 201);
          }
          return _json({'schemaVersion': 1, 'receipt': _receipt()}, 201);
        }),
      );
      addTearDown(transport.close);
      final api = RoomComfortApi(transport, _session(), isCurrent: () => true);
      final plan = await api.loadPlan();
      final preview = await api.preview(plan, '5' * 32);
      final receipt = await api.confirm(preview);

      expect(receipt.status, 'unknown');
      expect(requests, hasLength(3));
      expect(
        requests.first.url.path,
        endsWith('/room-comfort/${'a' * 32}/${'b' * 32}/plan'),
      );
      expect(jsonDecode(requests[1].body), {
        'schemaVersion': 1,
        'requestId': '5' * 32,
        'expectedPlanId': 'd' * 32,
        'expectedHomeRevision': 1,
        'expectedPolicyRevision': 2,
      });
      expect(jsonDecode(requests[2].body), {
        'schemaVersion': 1,
        'expectedPlanId': 'd' * 32,
        'expectedPolicyRevision': 2,
        'confirmToken': 'T' * 43,
      });
    },
  );

  test(
    'foreign account and malformed receipt projections fail closed',
    () async {
      for (final response in [
        {
          'schemaVersion': 1,
          'plan': {..._plan(), 'actorAccountId': '9' * 32},
        },
        {
          'schemaVersion': 1,
          'receipt': {
            ..._receipt(),
            'results': [
              {
                ...((_receipt()['results']! as List).single as Map),
                'secret': 'hidden',
              },
            ],
          },
        },
      ]) {
        final transport = LarenorServerApi(
          endpoint: _session().endpoint,
          client: MockClient((request) async => _json(response)),
        );
        addTearDown(transport.close);
        final api = RoomComfortApi(
          transport,
          _session(),
          isCurrent: () => true,
        );
        if (response.containsKey('plan')) {
          await expectLater(
            api.loadPlan(),
            throwsA(isA<LarenorServerException>()),
          );
        } else {
          final preview = RoomComfortPreview(
            id: '4' * 32,
            planId: 'd' * 32,
            policyRevision: 2,
            token: 'T' * 43,
            expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
            commandCount: 1,
          );
          await expectLater(
            api.confirm(preview),
            throwsA(isA<LarenorServerException>()),
          );
        }
      }
    },
  );

  test(
    'late Core response is discarded when route authority changes',
    () async {
      var current = true;
      final pending = Completer<http.Response>();
      final transport = LarenorServerApi(
        endpoint: _session().endpoint,
        client: MockClient((_) => pending.future),
      );
      addTearDown(transport.close);
      final api = RoomComfortApi(
        transport,
        _session(),
        isCurrent: () => current,
      );
      final future = api.loadPlan();
      await Future<void>.delayed(Duration.zero);
      current = false;
      pending.complete(_json({'schemaVersion': 1, 'plan': _plan()}));
      await expectLater(
        future,
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
    },
  );
}
