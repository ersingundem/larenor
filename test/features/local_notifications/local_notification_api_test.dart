import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/local_notifications/data/local_notification_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

ServerContext context() => ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
});
ServerSession session() => ServerSession(
  endpoint: ServerEndpoint('https://core.invalid'),
  accessToken: 'x' * 43,
  refreshToken: 'y' * 43,
  expiresAt: DateTime.utc(2026, 10),
  context: context(),
  user: ServerUser(
    id: 'c' * 32,
    username: 'fixture',
    role: ServerRole.member,
    mustChangePassword: false,
  ),
);
http.Response json(Object? value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, Object?> subscription(String id, int revision) => {
  'subscription': {
    'schemaVersion': 1,
    'ref': {
      ...context().toJson(),
      'kind': 'local_notification_subscription',
      'id': id,
    },
    'revision': revision,
    'permission': 'granted',
    'state': 'active',
    'expiresAt': 1790812800.0,
  },
};

Map<String, Object?> notification() => {
  'schemaVersion': 1,
  'id': 'e' * 32,
  'sequence': 1,
  'category': 'security',
  'sensitivity': 'private',
  'title': 'Secret',
  'body': 'Body',
  'target': '/today',
  'createdAt': 1788609600.0,
  'deliveryState': 'delivered',
  'readState': 'unread',
  'acknowledged': false,
  'publicProjection': {
    'title': 'Larenor',
    'body': '',
    'target': null,
    'redacted': true,
  },
};

void main() {
  test(
    'adapter binds register pull and ack to one authenticated Core scope',
    () async {
      final requests = <http.Request>[];
      final transport = LarenorServerApi(
        endpoint: session().endpoint,
        client: MockClient((request) async {
          requests.add(request);
          expect(request.headers['authorization'], 'Bearer ${'x' * 43}');
          if (request.method == 'POST' &&
              request.url.path.endsWith('/subscriptions')) {
            return json(subscription('d' * 32, 1), 201);
          }
          if (request.method == 'GET') {
            expect(request.url.queryParameters, {
              'expectedRevision': '1',
              'limit': '50',
            });
            return json({
              'schemaVersion': 1,
              'scope': context().toJson(),
              'subscriptionRevision': 1,
              'events': [notification()],
              'nextAfter': null,
            });
          }
          expect(request.method, 'POST');
          return json({
            'schemaVersion': 1,
            'subscriptionRevision': 1,
            'acknowledgedThrough': 1,
          });
        }),
      );
      addTearDown(transport.close);
      final api = LocalNotificationApi(
        transport,
        session(),
        isCurrent: () => true,
      );
      final registered = await api.register(
        id: 'd' * 32,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          1790812800000,
          isUtc: true,
        ),
      );
      final page = await api.pull(registered);
      await api.acknowledge(registered, page.events.single);
      expect(requests, hasLength(3));
      expect(jsonDecode(requests.first.body)['permission'], 'granted');
    },
  );

  test(
    'late response is cancelled after route or account authority retires',
    () async {
      var current = true;
      final pending = Completer<http.Response>();
      final transport = LarenorServerApi(
        endpoint: session().endpoint,
        client: MockClient((_) => pending.future),
      );
      addTearDown(transport.close);
      final api = LocalNotificationApi(
        transport,
        session(),
        isCurrent: () => current,
      );
      final future = api.register(
        id: 'd' * 32,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          1790812800000,
          isUtc: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      pending.complete(json(subscription('d' * 32, 1), 201));
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
