import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oikos/features/keenetic/data/keenetic_api_exception.dart';
import 'package:oikos/features/keenetic/data/keenetic_client.dart';
import 'package:oikos/features/keenetic/data/keenetic_config.dart';

void main() {
  const config = KeeneticConfig(
    baseUrl: 'http://192.168.1.1',
    username: 'admin',
    password: 'secret',
  );

  Future<KeeneticClient> loggedInClient(
    Future<http.Response> Function(http.Request) handler,
  ) async {
    var authenticated = false;
    final client = KeeneticClient(
      config: config,
      httpClient: MockClient((request) async {
        if (request.url.path == '/auth') {
          if (!authenticated && request.method == 'GET') {
            return http.Response(
              '',
              401,
              headers: {'x-ndm-challenge': 'chal123', 'x-ndm-realm': 'realm1'},
            );
          }
          if (request.method == 'POST') {
            authenticated = true;
            return http.Response(
              '',
              200,
              headers: {'set-cookie': 'session=abc123; Path=/; HttpOnly'},
            );
          }
        }
        return handler(request);
      }),
    );
    await client.login();
    return client;
  }

  group('login', () {
    test('computes sha256(challenge + md5(login:realm:password)) and replays the cookie', () async {
      final expectedMd5 = md5
          .convert(utf8.encode('admin:realm1:secret'))
          .toString();
      final expectedHash = sha256
          .convert(utf8.encode('chal123$expectedMd5'))
          .toString();

      var sawAuthPost = false;
      final client = KeeneticClient(
        config: config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth' && request.method == 'GET') {
            return http.Response(
              '',
              401,
              headers: {'x-ndm-challenge': 'chal123', 'x-ndm-realm': 'realm1'},
            );
          }
          if (request.url.path == '/auth' && request.method == 'POST') {
            sawAuthPost = true;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['login'], 'admin');
            expect(body['password'], expectedHash);
            return http.Response(
              '',
              200,
              headers: {'set-cookie': 'session=abc123; Path=/'},
            );
          }
          return http.Response('', 404);
        }),
      );

      await client.login();
      expect(sawAuthPost, isTrue);

      // A later request should replay the session cookie.
      final followUp = KeeneticClient(
        config: config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth') {
            return http.Response(
              '',
              200,
              headers: {'set-cookie': 'session=xyz789; Path=/'},
            );
          }
          expect(request.headers['Cookie'], 'session=xyz789');
          return http.Response(jsonEncode({'host': []}), 200);
        }),
      );
      await followUp.login();
      await followUp.getConnectedDevices();
    });

    test(
      'treats a 200 on the initial GET /auth as already authenticated',
      () async {
        final client = KeeneticClient(
          config: config,
          httpClient: MockClient((request) async {
            expect(request.method, 'GET');
            return http.Response(
              '',
              200,
              headers: {'set-cookie': 'session=ok'},
            );
          }),
        );
        await client.login();
      },
    );

    test('throws when the router does not send a challenge', () async {
      final client = KeeneticClient(
        config: config,
        httpClient: MockClient((request) async => http.Response('', 401)),
      );
      expect(client.login(), throwsA(isA<KeeneticApiException>()));
    });
  });

  group('getConnectedDevices', () {
    test('unwraps a {host: []} envelope', () async {
      final client = await loggedInClient((request) async {
        expect(request.url.path, '/rci/show/ip/hotspot');
        return http.Response(
          jsonEncode({
            'host': [
              {'mac': 'AA:BB', 'name': 'Phone', 'active': true},
            ],
          }),
          200,
        );
      });

      final devices = await client.getConnectedDevices();
      expect(devices.single.name, 'Phone');
    });
  });

  group('getAccessPoints', () {
    test('filters interfaces to type == AccessPoint', () async {
      final client = await loggedInClient((request) async {
        expect(request.url.path, '/rci/show/interface');
        return http.Response(
          jsonEncode([
            {'id': 'GigabitEthernet0', 'type': 'GigabitEthernet'},
            {
              'id': 'WifiMaster0/AccessPoint0',
              'type': 'AccessPoint',
              'state': 'up',
            },
          ]),
          200,
        );
      });

      final aps = await client.getAccessPoints();
      expect(aps, hasLength(1));
      expect(aps.single.id, 'WifiMaster0/AccessPoint0');
    });
  });

  group('setInterfaceUp', () {
    test('POSTs a parse command array to /rci/', () async {
      final client = await loggedInClient((request) async {
        expect(request.url.path, '/rci/');
        final body = jsonDecode(request.body) as List<dynamic>;
        expect(body.single, {
          'parse': 'interface WifiMaster0/AccessPoint0 down',
        });
        return http.Response('', 200);
      });

      await client.setInterfaceUp('WifiMaster0/AccessPoint0', false);
    });
  });

  group('getPortForwardingRules', () {
    test('parses a raw array response', () async {
      final client = await loggedInClient((request) async {
        expect(request.url.path, '/rci/ip/static');
        return http.Response(
          jsonEncode([
            {'protocol': 'tcp', 'port': 8123, 'to': '192.168.1.50'},
          ]),
          200,
        );
      });

      final rules = await client.getPortForwardingRules();
      expect(rules.single.toAddress, '192.168.1.50');
    });
  });
}
