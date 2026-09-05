import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/keenetic/data/keenetic_api_exception.dart';
import 'package:larenor/features/keenetic/data/keenetic_client.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';

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

    test('replays the session cookie from the initial 401 challenge on the '
        'follow-up POST /auth', () async {
      var sawPostCookie = '';
      final client = KeeneticClient(
        config: config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth' && request.method == 'GET') {
            return http.Response(
              '',
              401,
              headers: {
                'x-ndm-challenge': 'chal123',
                'x-ndm-realm': 'realm1',
                'set-cookie': 'sdid=preauth123; Path=/',
              },
            );
          }
          if (request.url.path == '/auth' && request.method == 'POST') {
            sawPostCookie = request.headers['Cookie'] ?? '';
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
      expect(sawPostCookie, 'sdid=preauth123');
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

    test(
      'keeps IDs from keyed responses and skips non-interface metadata',
      () async {
        final client = await loggedInClient(
          (request) async => http.Response(
            jsonEncode({
              'prompt': '(config)',
              'WifiMaster1/AccessPoint0': {
                'type': 'AccessPoint',
                'state': 'down',
                'link': 'up',
              },
            }),
            200,
          ),
        );
        final aps = await client.getAccessPoints();
        expect(aps.single.id, 'WifiMaster1/AccessPoint0');
        expect(aps.single.up, isFalse);
      },
    );
  });

  group('setInterfaceUp', () {
    test('POSTs interface change and save in one router-side batch', () async {
      final client = await loggedInClient((request) async {
        expect(request.url.path, '/rci/');
        final body = jsonDecode(request.body) as List<dynamic>;
        expect(body, [
          {'parse': 'interface WifiMaster0/AccessPoint0 down'},
          {'parse': 'system configuration save'},
        ]);
        return http.Response('', 200);
      });

      await client.setInterfaceUp('WifiMaster0/AccessPoint0', false);
    });

    test(
      'rejects non-Wi-Fi IDs and command injection before sending',
      () async {
        final client = KeeneticClient(
          config: config,
          httpClient: MockClient((_) async {
            fail('An invalid interface must not reach the router.');
          }),
        );
        for (final id in [
          'Home',
          'WifiMaster0/AccessPoint0\nsystem reboot',
          '',
        ]) {
          await expectLater(
            client.setInterfaceUp(id, false),
            throwsA(isA<KeeneticApiException>()),
          );
        }
      },
    );

    test('surfaces nested RCI errors even when HTTP returns 200', () async {
      final client = await loggedInClient(
        (request) async => http.Response(
          jsonEncode([
            {
              'parse': [
                {'status': 'error', 'message': 'Permission denied'},
              ],
            },
          ]),
          200,
        ),
      );
      await expectLater(
        client.setInterfaceUp('WifiMaster0/AccessPoint0', true),
        throwsA(
          isA<KeeneticApiException>().having(
            (error) => error.message,
            'message',
            'Router rejected the command.',
          ),
        ),
      );
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

  group('session recovery', () {
    test(
      'reauthenticates once for simultaneous expired-session reads',
      () async {
        var authRequests = 0;
        var unauthorized = 0;
        final bothRejected = Completer<void>();
        final client = KeeneticClient(
          config: config,
          httpClient: MockClient((request) async {
            if (request.url.path == '/auth') {
              authRequests++;
              await bothRejected.future;
              return http.Response(
                '',
                200,
                headers: {'set-cookie': 'session=new; Path=/'},
              );
            }
            if (request.headers['Cookie'] != 'session=new') {
              unauthorized++;
              if (unauthorized == 2) bothRejected.complete();
              return http.Response('', 401);
            }
            return http.Response(
              request.url.path.endsWith('hotspot') ? '{"host":[]}' : '{}',
              200,
            );
          }),
        );
        await Future.wait([
          client.getConnectedDevices(),
          client.getAccessPoints(),
        ]);
        expect(authRequests, 1);
        expect(unauthorized, 2);
      },
    );

    test('stops after one authentication retry', () async {
      var apiRequests = 0;
      final client = KeeneticClient(
        config: config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth') {
            return http.Response(
              '',
              200,
              headers: {'set-cookie': 'session=new'},
            );
          }
          apiRequests++;
          return http.Response('', 401);
        }),
      );
      await expectLater(
        client.getConnectedDevices(),
        throwsA(isA<KeeneticApiException>()),
      );
      expect(apiRequests, 2);
    });

    test('does not retry a forbidden mutation', () async {
      var requests = 0;
      final client = KeeneticClient(
        config: config,
        httpClient: MockClient((request) async {
          requests++;
          return http.Response('', 403);
        }),
      );
      await expectLater(
        client.setInterfaceUp('WifiMaster0/AccessPoint0', true),
        throwsA(isA<KeeneticApiException>()),
      );
      expect(requests, 1);
    });

    test('retains multiple cookies and handles Expires commas', () async {
      final client = KeeneticClient(
        config: config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth') {
            return http.Response(
              '',
              200,
              headers: {
                'set-cookie': 'session=one; Expires=Wed, 09 Jun 2038 10:18:14 GMT; Path=/, route=two; Path=/',
              },
            );
          }
          expect(request.headers['Cookie'], 'session=one; route=two');
          return http.Response('{"host":[]}', 200);
        }),
      );
      await client.login();
      await client.getConnectedDevices();
    });
  });

  test('checkConnection rejects an HTML login page with status 200', () async {
    final client = KeeneticClient(
      config: config,
      httpClient: MockClient(
        (request) async => http.Response('<html>Log in</html>', 200),
      ),
    );
    await expectLater(
      client.checkConnection(),
      throwsA(isA<KeeneticApiException>()),
    );
  });

  test('loads router identity and system metrics', () async {
    final client = await loggedInClient(
      (request) async => http.Response(
        request.url.path.endsWith('version')
            ? '{"model":"Keenetic Giga","release":"4.2.4"}'
            : '{"hostname":"Home","cpuload":8,"memory":"65536/262144","uptime":"90061"}',
        200,
      ),
    );
    final router = await client.getRouterStatus();
    expect(router.model, 'Keenetic Giga');
    expect(router.firmware, '4.2.4');
    expect(router.hostname, 'Home');
    expect(router.memoryPercent, 25);
    expect(router.uptimeSeconds, 90061);
  });
}
