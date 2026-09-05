import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_guest.dart';
import 'package:larenor/features/proxmox/data/proxmox_api_exception.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';

const fixtureConfig = ProxmoxConfig(
  host: 'proxmox.test',
  port: 8006,
  username: 'fixture',
  realm: 'pam',
  password: 'not-a-real-password',
  allowSelfSigned: false,
);
http.Response dataResponse(Object? data) =>
    http.Response(jsonEncode({'data': data}), 200);
http.Response authResponse() => dataResponse({
  'ticket': 'fixture-ticket',
  'CSRFPreventionToken': 'fixture-csrf',
});
void main() {
  final mutations = <String, Future<Object?> Function(ProxmoxClient)>{
    'power': (c) => c.powerAction('pve', ProxmoxGuestType.qemu, 100, 'start'),
    'config': (c) =>
        c.updateGuestConfig('pve', ProxmoxGuestType.qemu, 100, {'cores': '2'}),
    'clone': (c) => c.cloneGuest('pve', ProxmoxGuestType.qemu, 100, newId: 101),
    'backup': (c) => c.triggerBackup('pve', vmid: 100, storage: 'backup'),
    'vnc': (c) => c.vncTicket('pve', 100),
    'term': (c) => c.termTicket('pve', 100),
  };
  for (final entry in mutations.entries) {
    test('${entry.key} auth rejection does not replay any write', () async {
      var logins = 0, writes = 0;
      final client = ProxmoxClient(
        config: fixtureConfig,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/access/ticket')) {
            logins++;
            return authResponse();
          }
          writes++;
          return http.Response('private server body', 401);
        }),
      );
      addTearDown(client.dispose);
      await expectLater(
        entry.value(client),
        throwsA(
          isA<ProxmoxApiException>().having(
            (e) => e.failure,
            'failure',
            ProxmoxFailure.authentication,
          ),
        ),
      );
      expect(logins, 1);
      expect(writes, 1);
      expect(client.authCookieValue, isEmpty);
    });
  }
  test('a read rejected once reauthenticates once; valid empty list becomes read evidence', () async {
    var logins = 0, reads = 0;
    final monitor = HealthMonitor();
    addTearDown(monitor.dispose);
    final client = ProxmoxClient(
      config: fixtureConfig,
      healthSession: monitor.bind(IntegrationId.proxmox, configured: true),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/access/ticket')) {
          logins++;
          return authResponse();
        }
        reads++;
        return reads == 1 ? http.Response('', 401) : dataResponse([]);
      }),
    );
    addTearDown(client.dispose);
    await client.login();
    expect(monitor.read(IntegrationId.proxmox).lastSuccessfulRead, isNull);
    expect(await client.getNodes(), isEmpty);
    expect(logins, 2);
    expect(reads, 2);
    expect(monitor.read(IntegrationId.proxmox).lastSuccessfulRead, isNotNull);
  });
  test('transport timeout and simultaneous same-target write cause no duplicate command', () async {
    final started = Completer<void>();
    var writes = 0;
    final client = ProxmoxClient(
      config: fixtureConfig,
      requestTimeout: const Duration(milliseconds: 20),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/access/ticket')) return authResponse();
        writes++;
        started.complete();
        return Completer<http.Response>().future;
      }),
    );
    addTearDown(client.dispose);
    final first = expectLater(
      client.powerAction('pve', ProxmoxGuestType.qemu, 100, 'start'),
      throwsA(
        isA<ProxmoxApiException>().having(
          (e) => e.failure,
          'failure',
          ProxmoxFailure.timeout,
        ),
      ),
    );
    await started.future;
    await expectLater(
      client.triggerBackup('pve', vmid: 100, storage: 'backup'),
      throwsA(
        isA<ProxmoxApiException>().having(
          (e) => e.failure,
          'failure',
          ProxmoxFailure.actionPending,
        ),
      ),
    );
    await first;
    expect(writes, 1);
  });
  test('disposal rejects a late login, clears runtime tickets and suppresses health', () async {
    final pending = Completer<http.Response>(),
        started = Completer<http.Response>();
    final monitor = HealthMonitor();
    addTearDown(monitor.dispose);
    final client = ProxmoxClient(
      config: fixtureConfig,
      healthSession: monitor.bind(IntegrationId.proxmox, configured: true),
      httpClient: MockClient((_) {
        started.complete(authResponse());
        return pending.future;
      }),
    );
    final result = expectLater(
      client.login(),
      throwsA(isA<ProxmoxApiException>()),
    );
    await started.future;
    client.dispose();
    pending.complete(authResponse());
    await result;
    expect(client.isAuthenticated, isFalse);
    expect(client.authCookieValue, isEmpty);
    expect(monitor.read(IntegrationId.proxmox).lastSuccessfulRead, isNull);
    await expectLater(client.getNodes(), throwsA(isA<ProxmoxApiException>()));
  });
  for (final data in [
    {'ticket': '', 'CSRFPreventionToken': 'x'},
    {'ticket': 'a\r\nCookie: other', 'CSRFPreventionToken': 'x'},
    {'ticket': 'normal', 'CSRFPreventionToken': 'x', 'NeedTFA': 1},
    {'ticket': 'PVE:!tfa!challenge', 'CSRFPreventionToken': 'x'},
  ]) {
    test(
      'partial/unsafe authentication material is not a usable session: ${data.keys}',
      () async {
        final client = ProxmoxClient(
          config: fixtureConfig,
          httpClient: MockClient((_) async => dataResponse(data)),
        );
        addTearDown(client.dispose);
        await expectLater(client.login(), throwsA(isA<ProxmoxApiException>()));
        expect(client.isAuthenticated, isFalse);
        expect(client.authCookieValue, isEmpty);
      },
    );
  }
  for (final body in <Object?>[
    null,
    {},
    [null],
    [
      {'node': 'same'},
      {'node': 'same'},
    ],
    [
      {'status': 'online'},
    ],
  ]) {
    test('invalid node data never becomes empty or healthy: $body', () async {
      final monitor = HealthMonitor();
      addTearDown(monitor.dispose);
      final client = ProxmoxClient(
        config: fixtureConfig,
        healthSession: monitor.bind(IntegrationId.proxmox, configured: true),
        httpClient: MockClient(
          (request) async => request.url.path.endsWith('/access/ticket')
              ? authResponse()
              : dataResponse(body),
        ),
      );
      addTearDown(client.dispose);
      await expectLater(client.getNodes(), throwsA(isA<ProxmoxApiException>()));
      expect(monitor.read(IntegrationId.proxmox).lastSuccessfulRead, isNull);
      expect(
        monitor.read(IntegrationId.proxmox).failure,
        HealthFailure.invalidResponse,
      );
    });
  }
  test(
    'failed LXC source does not become an empty successful combined guest list',
    () async {
      final monitor = HealthMonitor();
      addTearDown(monitor.dispose);
      final client = ProxmoxClient(
        config: fixtureConfig,
        healthSession: monitor.bind(IntegrationId.proxmox, configured: true),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/access/ticket')) {
            return authResponse();
          }
          if (request.url.path.endsWith('/lxc')) return http.Response('', 403);
          return dataResponse([
            {'vmid': 100, 'status': 'running'},
          ]);
        }),
      );
      addTearDown(client.dispose);
      await expectLater(
        client.getGuests('pve'),
        throwsA(isA<ProxmoxApiException>()),
      );
      expect(monitor.read(IntegrationId.proxmox).lastSuccessfulRead, isNull);
      expect(
        monitor.read(IntegrationId.proxmox).failure,
        HealthFailure.permission,
      );
    },
  );
  test(
    'server errors, redirects, and excessive bodies never expose response text',
    () async {
      for (final response in [
        http.Response('private-host-secret', 403),
        http.Response('', 302, headers: {'location': 'https://evil.test'}),
        http.Response('x' * (2 * 1024 * 1024 + 1), 200),
      ]) {
        var calls = 0;
        final client = ProxmoxClient(
          config: fixtureConfig,
          httpClient: MockClient((request) async {
            calls++;
            expect(request.followRedirects, isFalse);
            return response;
          }),
        );
        await expectLater(
          client.login(),
          throwsA(
            isA<ProxmoxApiException>().having(
              (e) => e.message.contains('private-host-secret'),
              'safe',
              false,
            ),
          ),
        );
        expect(calls, 1);
        client.dispose();
      }
    },
  );
}
