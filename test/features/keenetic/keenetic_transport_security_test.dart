import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/keenetic/data/keenetic_api_exception.dart';
import 'package:larenor/features/keenetic/data/keenetic_client.dart';
import 'package:larenor/features/keenetic/data/keenetic_telemetry.dart';

import 'keenetic_telemetry_test.dart' show fixtureConfig;

void main() {
  for (final status in [401, 403, 500]) {
    test(
      'mutation HTTP$status is sent exactly once with no implicit authentication',
      () async {
        var calls = 0;
        final client = KeeneticClient(
          config: fixtureConfig,
          httpClient: MockClient((request) async {
            calls++;
            expect(request.url.path, '/proxy/rci/');
            return http.Response('private-password-hostname', status);
          }),
        );
        addTearDown(client.dispose);
        await expectLater(
          client.setInterfaceUp('WifiMaster0/AccessPoint0', true),
          throwsA(
            isA<KeeneticApiException>()
                .having((e) => e.statusCode, 'status', status)
                .having((e) => e.message.contains('private'), 'safe', false),
          ),
        );
        expect(calls, 1);
      },
    );
  }
  test(
    'duplicate in-flight interface writes are rejected without another command',
    () async {
      final pending = Completer<http.Response>();
      final started = Completer<void>();
      var calls = 0;
      final client = KeeneticClient(
        config: fixtureConfig,
        httpClient: MockClient((_) {
          calls++;
          started.complete();
          return pending.future;
        }),
      );
      addTearDown(client.dispose);
      final first = client.setInterfaceUp('WifiMaster0/AccessPoint0', true);
      await started.future;
      await expectLater(
        client.setInterfaceUp('WifiMaster0/AccessPoint0', false),
        throwsA(isA<KeeneticApiException>()),
      );
      expect(calls, 1);
      pending.complete(http.Response('', 200));
      await first;
    },
  );
  test('timeout has safe typed error and mutation is not retried', () async {
    var calls = 0;
    final client = KeeneticClient(
      config: fixtureConfig,
      requestTimeout: const Duration(milliseconds: 1),
      httpClient: MockClient((_) {
        calls++;
        return Completer<http.Response>().future;
      }),
    );
    addTearDown(client.dispose);
    await expectLater(
      client.setInterfaceUp('WifiMaster0/AccessPoint0', false),
      throwsA(
        isA<KeeneticApiException>().having(
          (e) => e.failure,
          'failure',
          KeeneticReadFailure.timeout,
        ),
      ),
    );
    expect(calls, 1);
  });
  test(
    'disposed pending login cannot restore cookies/authentication or health',
    () async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      final monitor = HealthMonitor();
      addTearDown(monitor.dispose);
      final client = KeeneticClient(
        config: fixtureConfig,
        healthSession: monitor.bind(IntegrationId.keenetic, configured: true),
        httpClient: MockClient((_) {
          started.complete();
          return response.future;
        }),
      );
      final pending = expectLater(
        client.login(),
        throwsA(isA<KeeneticApiException>()),
      );
      await started.future;
      client.dispose();
      response.complete(
        http.Response('', 200, headers: {'set-cookie': 'session=late; Path=/'}),
      );
      await pending;
      expect(client.isAuthenticated, isFalse);
      expect(monitor.read(IntegrationId.keenetic).lastSuccessfulRead, isNull);
      await expectLater(
        Future.sync(client.getConnectedDevices),
        throwsA(isA<KeeneticApiException>()),
      );
    },
  );
  test('cookie origin, path, secure, expiry scope is honored; sessions stay in memory', () async {
    final cookies = <String?>[];
    final client = KeeneticClient(
      config: fixtureConfig,
      now: () => DateTime.utc(2026),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/auth')) {
          return http.Response(
            '',
            200,
            headers: {
              'set-cookie':
                  'ok=yes; Path=/proxy, wrongDomain=no; Domain=evil.test; Path=/, '
                  'authOnly=no; Path=/proxy/auth, tlsOnly=no; Secure; Path=/, '
                  'expired=no; Max-Age=-1; Path=/, boundary=no; Path=/prox',
            },
          );
        }
        cookies.add(request.headers['Cookie']);
        return http.Response('{"host":[]}', 200);
      }),
    );
    addTearDown(client.dispose);
    await client.login();
    await client.getConnectedDevices();
    expect(cookies, ['ok=yes']);
  });
  test('cross-origin redirects are never followed with credentials', () async {
    var calls = 0;
    final client = KeeneticClient(
      config: fixtureConfig,
      httpClient: MockClient((request) async {
        calls++;
        expect(request.followRedirects, isFalse);
        expect(request.url.host, 'router.test');
        return http.Response(
          '',
          302,
          headers: {'location': 'https://evil.test/'},
        );
      }),
    );
    addTearDown(client.dispose);
    await expectLater(client.login(), throwsA(isA<KeeneticApiException>()));
    expect(calls, 1);
  });
  for (final body in [
    '{}',
    '<html>Sign in</html>',
    jsonEncode({'message': 'private'}),
  ]) {
    test('connection verification rejects no identity: $body', () async {
      final client = KeeneticClient(
        config: fixtureConfig,
        httpClient: MockClient((_) async => http.Response(body, 200)),
      );
      addTearDown(client.dispose);
      await expectLater(
        client.checkConnection(),
        throwsA(isA<KeeneticApiException>()),
      );
    });
  }
  test('oversize responses fail closed', () async {
    final client = KeeneticClient(
      config: fixtureConfig,
      httpClient: MockClient(
        (_) async => http.Response('x' * (2 * 1024 * 1024 + 1), 200),
      ),
    );
    addTearDown(client.dispose);
    await expectLater(
      client.getConnectedDevices(),
      throwsA(isA<KeeneticApiException>()),
    );
  });
}
