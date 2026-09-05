import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/synthetic_ha_server.dart';

void main() {
  test(
    'E2E fixture blocks redirects before opening a different loopback port',
    () async {
      final trap = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var escaped = 0;
      trap.listen((request) async {
        escaped++;
        await request.response.close();
      });
      fixture.listen((request) async {
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://127.0.0.1:${trap.port}/trap',
        );
        await request.response.close();
      });
      final policy = FixtureNetwork(fixture.port);
      final client = policy.createHttpClient(null);
      try {
        await expectLater(() async {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${fixture.port}/redirect'),
          );
          await request.close();
        }(), throwsA(isA<SocketException>()));
        expect(escaped, 0);
        expect(policy.blocked, 1);
      } finally {
        client.close(force: true);
        await fixture.close(force: true);
        await trap.close(force: true);
      }
    },
  );

  test('E2E fixture rejects proxy sockets even for an allowed URL', () async {
    final trap = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var escaped = 0;
    trap.listen((request) async {
      escaped++;
      await request.response.close();
    });
    final policy = FixtureNetwork(fixture.port);
    final client = policy.createHttpClient(null)
      ..findProxy = (_) => 'PROXY 127.0.0.1:${trap.port}';
    try {
      await expectLater(() async {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${fixture.port}/'),
        );
        await request.close();
      }(), throwsA(isA<SocketException>()));
      expect(escaped, 0);
      expect(policy.blocked, 1);
    } finally {
      client.close(force: true);
      await fixture.close(force: true);
      await trap.close(force: true);
    }
  });

  test('E2E fixture permits its exact loopback endpoint', () async {
    final fixture = await SyntheticHaServer.start();
    final policy = FixtureNetwork(fixture.port);
    final client = policy.createHttpClient(null);
    try {
      final request = await client.getUrl(Uri.parse('${fixture.baseUrl}/api/'));
      request.headers.set('authorization', 'Bearer ${SyntheticHaServer.token}');
      final response = await request.close();
      expect(response.statusCode, 200);
      await response.drain<void>();
      expect(policy.blocked, 0);
    } finally {
      client.close(force: true);
      await fixture.close();
    }
  });

  test(
    'manual response redirect cannot escape the fixture socket boundary',
    () async {
      final trap = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var escaped = 0;
      trap.listen((request) async {
        escaped++;
        await request.response.close();
      });
      fixture.listen((request) async {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/same-origin');
        await request.response.close();
      });
      final policy = FixtureNetwork(fixture.port);
      final client = policy.createHttpClient(null);
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${fixture.port}/'),
        );
        request.followRedirects = false;
        final response = await request.close();
        await expectLater(
          () async => response.redirect(
            null,
            Uri.parse('http://127.0.0.1:${trap.port}/trap'),
          ),
          throwsA(isA<SocketException>()),
        );
        expect(escaped, 0);
        expect(policy.blocked, 1);
      } finally {
        client.close(force: true);
        await fixture.close(force: true);
        await trap.close(force: true);
      }
    },
  );

  test('CONNECT proxy cannot open a socket outside the fixture', () async {
    final trap = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var escaped = 0;
    trap.listen((request) async {
      escaped++;
      await request.response.close();
    });
    final policy = FixtureNetwork(fixture.port);
    final client = policy.createHttpClient(null)
      ..findProxy = (_) => 'PROXY 127.0.0.1:${trap.port}';
    try {
      await expectLater(() async {
        final request = await client.openUrl(
          'CONNECT',
          Uri.parse('http://127.0.0.1:${fixture.port}/'),
        );
        await request.close();
      }(), throwsA(isA<SocketException>()));
      expect(escaped, 0);
      expect(policy.blocked, 1);
    } finally {
      client.close(force: true);
      await fixture.close(force: true);
      await trap.close(force: true);
    }
  });
}
