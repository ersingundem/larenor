import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/media/data/media_api_exception.dart';
import 'package:larenor/features/media/qbittorrent/data/qbittorrent_client.dart';
import 'package:larenor/features/media/qbittorrent/data/qbittorrent_config.dart';
import 'package:qbittorrent_api/qbittorrent_api.dart';

const testConfig = QbittorrentConfig(
  baseUrl: 'http://qb.local:8080/proxy/qb',
  username: 'test-user',
  password: 'test-secret<&>',
);
const hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final target = Torrents(hashes: [hash]);

class QbHttp extends MockClient {
  QbHttp(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

class RawHttp extends http.BaseClient {
  RawHttp(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

http.Response? authenticatedResponse(
  http.Request request, {
  String app = 'v5.2.3',
  String api = '2.15.1',
  String cookie = 'QBT_SID_8080=test-session; Path=/; HttpOnly',
  int loginStatus = 204,
}) {
  if (request.url.path.endsWith('/auth/login')) {
    return http.Response(
      loginStatus == 200 ? 'Ok.' : '',
      loginStatus,
      headers: {'set-cookie': cookie},
    );
  }
  if (request.url.path.endsWith('/app/version')) return http.Response(app, 200);
  if (request.url.path.endsWith('/app/webapiVersion')) {
    return http.Response(api, 200);
  }
  return null;
}

void main() {
  test(
    '5.2 login requires scoped cookie plus authenticated version reads',
    () async {
      final requests = <http.Request>[];
      final transport = QbHttp((request) async {
        requests.add(request);
        expect(request.followRedirects, isFalse);
        expect(request.url.path, startsWith('/proxy/qb/api/v2/'));
        expect(request.headers['Origin'], 'http://qb.local:8080');
        expect(request.headers['Referer'], '${testConfig.baseUrl}/');
        if (request.url.path.endsWith('/auth/login')) {
          expect(request.method, 'POST');
          expect(request.bodyFields, {
            'username': testConfig.username,
            'password': testConfig.password,
          });
          expect(request.headers['Cookie'], isNull);
        } else {
          expect(request.method, 'GET');
          expect(request.headers['Cookie'], 'QBT_SID_8080=test-session');
        }
        return authenticatedResponse(request)!;
      });
      final client = QbittorrentClient(
        config: testConfig,
        httpClient: transport,
      );
      await client.login();
      expect(requests.map((r) => r.url.path.split('/').last), [
        'login',
        'version',
        'webapiVersion',
      ]);
      expect(client.isAuthenticated, isTrue);
      expect(client.applicationVersion, 'v5.2.3');
      expect(client.webApiVersion, '2.15.1');
      client.dispose();
      expect(transport.closed, isTrue);
      expect(client.isAuthenticated, isFalse);
      expect(client.applicationVersion, isNull);
      await expectLater(
        client.torrents.getTorrentsList(),
        throwsA(isA<MediaApiException>()),
      );
      expect(requests, hasLength(3));
    },
  );

  for (final setup in [
    (4, 'v4.6.7', '2.9.3', 'SID=session; Path=/', 200),
    (5, 'v5.0.0', '2.11.2', 'SID=session; Path=/', 200),
    (5, 'v5.2.3', '2.15.1', 'QBT_SID_9090=session; Path=/', 204),
  ]) {
    test(
      'qB ${setup.$2} uses its exact mutation endpoints without retries',
      () async {
        final writes = <http.Request>[];
        final client = QbittorrentClient(
          config: testConfig,
          httpClient: MockClient((request) async {
            final auth = authenticatedResponse(
              request,
              app: setup.$2,
              api: setup.$3,
              cookie: setup.$4,
              loginStatus: setup.$5,
            );
            if (auth != null) return auth;
            writes.add(request);
            expect(request.method, 'POST');
            expect(request.bodyFields['hashes'], hash);
            return http.Response('', setup.$1 == 4 ? 200 : 204);
          }),
        );
        addTearDown(client.dispose);
        await client.login();
        await client.torrents.pauseTorrents(torrents: target);
        await client.torrents.resumeTorrents(torrents: target);
        await client.torrents.deleteTorrents(torrents: target);
        expect(writes.map((r) => r.url.path.split('/').last), [
          setup.$1 == 4 ? 'pause' : 'stop',
          setup.$1 == 4 ? 'resume' : 'start',
          'delete',
        ]);
        expect(writes.last.bodyFields['deleteFiles'], 'false');
      },
    );
  }

  test(
    'login HTTP success without a usable session cookie is not evidence',
    () async {
      for (final status in [200, 204]) {
        var calls = 0;
        final client = QbittorrentClient(
          config: testConfig,
          httpClient: MockClient((_) async {
            calls++;
            return http.Response(status == 200 ? 'Ok.' : '', status);
          }),
        );
        await expectLater(client.login(), throwsA(isA<MediaApiException>()));
        expect(calls, 1);
        expect(client.isAuthenticated, isFalse);
        client.dispose();
      }
    },
  );

  test('legacy Fails response is rejected even with a cookie', () async {
    final client = QbittorrentClient(
      config: testConfig,
      httpClient: MockClient(
        (_) async => http.Response(
          'Fails.',
          200,
          headers: {'set-cookie': 'SID=test; Path=/'},
        ),
      ),
    );
    addTearDown(client.dispose);
    await expectLater(client.login(), throwsA(isA<MediaApiException>()));
    expect(client.isAuthenticated, isFalse);
  });

  for (final cookie in [
    'SID=test; Domain=elsewhere.local; Path=/',
    'SID=test; Domain=local; Path=/',
    'SID=test; Path=/proxy/other',
    'SID=test; Path=/proxy/qb/api/v2/auth',
    'SID=test',
    'SID=test; Path=/; Secure',
    'SID=test; Path=/; Max-Age=0',
    'SID=test; Path=/; Expires=Wed, 01 Jan 2020 00:00:00 GMT',
    'SID=; Path=/',
    'SID=a; Path=/, SID=b; Path=/',
    'SID=a; Path=/, QBT_SID_8080=b; Path=/',
    'unrelated=test; Path=/',
  ]) {
    test(
      'rejects invalid, expired or ambiguous session cookie: ${cookie.split(';').first}',
      () async {
        var calls = 0;
        final client = QbittorrentClient(
          config: testConfig,
          httpClient: MockClient((request) async {
            calls++;
            return authenticatedResponse(request, cookie: cookie)!;
          }),
        );
        addTearDown(client.dispose);
        await expectLater(client.login(), throwsA(isA<MediaApiException>()));
        expect(calls, 1);
        expect(client.isAuthenticated, isFalse);
      },
    );
  }

  test('ignores unrelated cookies, accepts Expires comma, preserves proxy and IPv6 origin', () async {
    const config = QbittorrentConfig(
      baseUrl: 'https://[fd00::1]:8443/proxy',
      username: 'a',
      password: 'b',
    );
    final client = QbittorrentClient(
      config: config,
      httpClient: MockClient((request) async {
        expect(request.headers['Origin'], 'https://[fd00::1]:8443');
        expect(request.headers['Referer'], '${config.baseUrl}/');
        if (!request.url.path.endsWith('/auth/login')) {
          expect(request.headers['Cookie'], 'QBT_SID_8080=test');
        }
        return authenticatedResponse(
          request,
          cookie: 'tracking=no; Path=/, QBT_SID_8080=test; Path=/proxy; Secure; Expires=Wed, 01 Jan 2031 00:00:00 GMT',
        )!;
      }),
    );
    addTearDown(client.dispose);
    await client.login();
    expect(client.isAuthenticated, isTrue);
  });

  for (final redirect in [301, 302, 303, 307, 308]) {
    test(
      'never follows HTTP $redirect with password or session cookie',
      () async {
        for (final afterLogin in [false, true]) {
          var redirects = 0;
          final client = QbittorrentClient(
            config: testConfig,
            httpClient: MockClient((request) async {
              expect(request.followRedirects, isFalse);
              expect(request.url.host, 'qb.local');
              if (afterLogin) {
                final auth = authenticatedResponse(request);
                if (auth != null) return auth;
              }
              redirects++;
              return http.Response(
                'test-secret<&>',
                redirect,
                headers: {'location': 'https://attacker.invalid/steal'},
              );
            }),
          );
          if (afterLogin) await client.login();
          await expectLater(
            afterLogin ? client.torrents.getTorrentsList() : client.login(),
            throwsA(
              isA<MediaApiException>().having(
                (e) => e.toString(),
                'safe error',
                allOf(
                  isNot(contains('test-secret')),
                  isNot(contains('attacker')),
                ),
              ),
            ),
          );
          expect(redirects, 1);
          client.dispose();
        }
      },
    );
  }

  for (final versions in [
    ('v5.2.3', '2.9.3'),
    ('v4.6.7', '2.15.1'),
    ('html secret', '2.15.1'),
    ('v6.0.0', '3.0.0'),
  ]) {
    test(
      'rejects inconsistent or unknown API version ${versions.$1}/${versions.$2}',
      () async {
        final client = QbittorrentClient(
          config: testConfig,
          httpClient: MockClient(
            (request) async => authenticatedResponse(
              request,
              app: versions.$1,
              api: versions.$2,
            )!,
          ),
        );
        addTearDown(client.dispose);
        await expectLater(client.login(), throwsA(isA<MediaApiException>()));
        expect(client.isAuthenticated, isFalse);
      },
    );
  }

  test('read parses new states, preserves unknown progress, maps filters and marks health', () async {
    final monitor = HealthMonitor();
    addTearDown(monitor.dispose);
    final health = monitor.bind(IntegrationId.qbittorrent, configured: true);
    final client = QbittorrentClient(
      config: testConfig,
      healthSession: health,
      httpClient: MockClient((request) async {
        final auth = authenticatedResponse(request);
        if (auth != null) return auth;
        expect(request.url.queryParameters['filter'], 'stopped');
        return http.Response(
          jsonEncode([
            {
              'hash': hash,
              'name': 'Local torrent',
              'state': 'stoppedDL',
              'progress': 0.25,
            },
            {'hash': 'b' * 40, 'state': 'newFutureState'},
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.dispose);
    expect(monitor.read(IntegrationId.qbittorrent).lastSuccessfulRead, isNull);
    await client.login();
    final items = await client.torrents.getTorrentsList(
      options: const TorrentListOptions(filter: TorrentFilter.paused),
    );
    expect(items[0].state, TorrentState.stoppedDL);
    expect(items[1].state, TorrentState.unknown);
    expect(items[1].progress, isNull);
    expect(
      monitor.read(IntegrationId.qbittorrent).lastSuccessfulRead,
      isNotNull,
    );
  });

  test(
    'empty JSON list is a successful read; malformed response is not empty',
    () async {
      var body = '[]';
      final monitor = HealthMonitor();
      addTearDown(monitor.dispose);
      final client = QbittorrentClient(
        config: testConfig,
        healthSession: monitor.bind(
          IntegrationId.qbittorrent,
          configured: true,
        ),
        httpClient: MockClient(
          (request) async =>
              authenticatedResponse(request) ?? http.Response(body, 200),
        ),
      );
      addTearDown(client.dispose);
      await client.login();
      expect(await client.torrents.getTorrentsList(), isEmpty);
      for (final invalid in [
        '{"secret":"test-secret"}',
        '<html>test-secret</html>',
        '[{"progress":3}]',
      ]) {
        body = invalid;
        await expectLater(
          client.torrents.getTorrentsList(),
          throwsA(
            isA<MediaApiException>().having(
              (e) => e.toString(),
              'safe',
              isNot(contains('test-secret')),
            ),
          ),
        );
        expect(
          monitor.read(IntegrationId.qbittorrent).failure,
          HealthFailure.invalidResponse,
        );
      }
    },
  );

  for (final status in [401, 403, 404, 500]) {
    test(
      'HTTP $status is typed and redacted; mutation never retries or relogs',
      () async {
        var mutations = 0;
        var logins = 0;
        final client = QbittorrentClient(
          config: testConfig,
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/auth/login')) logins++;
            final auth = authenticatedResponse(request);
            if (auth != null) return auth;
            mutations++;
            return http.Response(
              'server echoed test-secret<&> SID=session',
              status,
            );
          }),
        );
        addTearDown(client.dispose);
        await client.login();
        await expectLater(
          client.torrents.pauseTorrents(torrents: target),
          throwsA(
            isA<MediaApiException>()
                .having((e) => e.statusCode, 'status', status)
                .having(
                  (e) => e.toString(),
                  'safe',
                  isNot(contains('test-secret')),
                ),
          ),
        );
        expect(mutations, 1);
        expect(logins, 1);
        if (status == 401 || status == 403) {
          expect(client.isAuthenticated, isFalse);
        }
      },
    );
  }

  test(
    'expired session never sends a write or silently reauthenticates',
    () async {
      var now = DateTime.utc(2026, 1);
      var calls = 0;
      final client = QbittorrentClient(
        config: testConfig,
        now: () => now,
        httpClient: MockClient((request) async {
          calls++;
          return authenticatedResponse(
            request,
            cookie: 'SID=test; Path=/; Max-Age=10',
          )!;
        }),
      );
      addTearDown(client.dispose);
      await client.login();
      now = now.add(const Duration(seconds: 11));
      await expectLater(
        client.torrents.deleteTorrents(torrents: target),
        throwsA(isA<MediaApiException>()),
      );
      expect(calls, 3);
    },
  );

  test('duplicate actions are guarded while pending; all or malformed targets rejected', () async {
    final pending = Completer<http.Response>();
    var writes = 0;
    final client = QbittorrentClient(
      config: testConfig,
      httpClient: MockClient((request) async {
        final auth = authenticatedResponse(request);
        if (auth != null) return auth;
        writes++;
        return pending.future;
      }),
    );
    addTearDown(client.dispose);
    await client.login();
    final first = client.torrents.pauseTorrents(torrents: target);
    await expectLater(
      client.torrents.deleteTorrents(torrents: target),
      throwsA(isA<MediaApiException>()),
    );
    for (final invalid in [
      Torrents.all(),
      Torrents(hashes: []),
      Torrents(hashes: ['wrong|all']),
    ]) {
      await expectLater(
        client.torrents.deleteTorrents(torrents: invalid),
        throwsA(isA<MediaApiException>()),
      );
    }
    pending.complete(http.Response('', 204));
    await first;
    expect(writes, 1);
  });

  test('late login response after dispose cannot establish a session or issue reads', () async {
    final response = Completer<http.Response>();
    var calls = 0;
    final transport = QbHttp((request) async {
      calls++;
      return response.future;
    });
    final client = QbittorrentClient(config: testConfig, httpClient: transport);
    final login = client.login();
    final result = expectLater(login, throwsA(isA<MediaApiException>()));
    client.dispose();
    response.complete(
      http.Response('', 204, headers: {'set-cookie': 'SID=test; Path=/'}),
    );
    await result;
    expect(calls, 1);
    expect(transport.closed, isTrue);
    expect(client.isAuthenticated, isFalse);
  });

  test(
    'timeout is bounded and a write is not automatically repeated',
    () async {
      final response = Completer<http.Response>();
      var writes = 0;
      final client = QbittorrentClient(
        config: testConfig,
        requestTimeout: const Duration(milliseconds: 10),
        httpClient: MockClient((request) async {
          final auth = authenticatedResponse(request);
          if (auth != null) return auth;
          writes++;
          return response.future;
        }),
      );
      addTearDown(client.dispose);
      await client.login();
      await expectLater(
        client.torrents.resumeTorrents(torrents: target),
        throwsA(
          isA<MediaApiException>().having(
            (e) => e.message,
            'uncertain',
            contains('may not have completed'),
          ),
        ),
      );
      expect(writes, 1);
      response.complete(http.Response('', 204));
    },
  );

  for (final major in [4, 5]) {
    test(
      'adds selected magnet and torrent bytes via scoped multipart on qB $major',
      () async {
        final bodies = <String>[];
        final client = QbittorrentClient(
          config: testConfig,
          httpClient: MockClient((request) async {
            final auth = authenticatedResponse(
              request,
              app: major == 4 ? 'v4.6.7' : 'v5.2.3',
              api: major == 4 ? '2.9.3' : '2.15.1',
              loginStatus: major == 4 ? 200 : 204,
            );
            if (auth != null) return auth;
            expect(request.url.path, '/proxy/qb/api/v2/torrents/add');
            expect(
              request.headers['content-type'],
              startsWith('multipart/form-data;'),
            );
            expect(request.headers['Cookie'], contains('test-session'));
            bodies.add(request.body);
            return http.Response('Ok.', 200);
          }),
        );
        addTearDown(client.dispose);
        await client.login();
        await client.torrents.addNewTorrents(
          torrents: const NewTorrents.urls(
            urls: [
              'magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            ],
            paused: true,
          ),
        );
        await client.torrents.addNewTorrents(
          torrents: NewTorrents.bytes(
            bytes: [
              FileBytes(
                filename: 'selected.torrent',
                bytes: Uint8List.fromList([100, 101]),
              ),
            ],
          ),
        );
        expect(
          bodies[0],
          contains('name="${major == 4 ? 'paused' : 'stopped'}"'),
        );
        expect(bodies[0], contains('magnet:?xt='));
        expect(bodies[1], contains('filename="selected.torrent"'));
        expect(bodies[1], contains('name="torrents"'));
        expect(bodies.every((body) => !body.contains('test-secret')), isTrue);
      },
    );
  }

  test(
    'authentication failure during verification never marks connected',
    () async {
      for (final failure in [401, 403]) {
        final monitor = HealthMonitor();
        final client = QbittorrentClient(
          config: testConfig,
          healthSession: monitor.bind(
            IntegrationId.qbittorrent,
            configured: true,
          ),
          httpClient: MockClient(
            (request) async => request.url.path.endsWith('/app/webapiVersion')
                ? http.Response('secret private response', failure)
                : authenticatedResponse(request)!,
          ),
        );
        await expectLater(client.login(), throwsA(isA<MediaApiException>()));
        expect(client.isAuthenticated, isFalse);
        expect(
          monitor.read(IntegrationId.qbittorrent).lastSuccessfulRead,
          isNull,
        );
        expect(
          monitor.read(IntegrationId.qbittorrent).failure,
          failure == 401
              ? HealthFailure.authentication
              : HealthFailure.permission,
        );
        client.dispose();
        monitor.dispose();
      }
    },
  );

  test(
    'cookie revoked during final version read cannot complete sign-in',
    () async {
      final client = QbittorrentClient(
        config: testConfig,
        httpClient: MockClient(
          (request) async => request.url.path.endsWith('/app/webapiVersion')
              ? http.Response(
                  '2.15.1',
                  200,
                  headers: {'set-cookie': 'SID=; Path=/; Max-Age=0'},
                )
              : authenticatedResponse(request)!,
        ),
      );
      addTearDown(client.dispose);
      await expectLater(client.login(), throwsA(isA<MediaApiException>()));
      expect(client.isAuthenticated, isFalse);
    },
  );

  test(
    'concurrent read cannot publish after another request revokes the session',
    () async {
      final lateResponse = Completer<http.Response>();
      var reads = 0;
      final monitor = HealthMonitor();
      addTearDown(monitor.dispose);
      final client = QbittorrentClient(
        config: testConfig,
        healthSession: monitor.bind(
          IntegrationId.qbittorrent,
          configured: true,
        ),
        httpClient: MockClient((request) async {
          final auth = authenticatedResponse(request);
          if (auth != null) return auth;
          reads++;
          return reads == 1 ? lateResponse.future : http.Response('', 401);
        }),
      );
      addTearDown(client.dispose);
      await client.login();
      final oldRead = client.torrents.getTorrentsList();
      final rejected = expectLater(oldRead, throwsA(isA<MediaApiException>()));
      await expectLater(
        client.torrents.getTorrentsList(),
        throwsA(isA<MediaApiException>()),
      );
      lateResponse.complete(http.Response('[]', 200));
      await rejected;
      expect(client.isAuthenticated, isFalse);
      expect(
        monitor.read(IntegrationId.qbittorrent).failure,
        HealthFailure.authentication,
      );
    },
  );

  test(
    'oversized and broken transport responses remain bounded and redacted',
    () async {
      for (final oversized in [true, false]) {
        final client = QbittorrentClient(
          config: testConfig,
          httpClient: MockClient((request) async {
            final auth = authenticatedResponse(request);
            if (auth != null) return auth;
            if (oversized) {
              return http.Response('x' * (2 * 1024 * 1024 + 1), 200);
            }
            throw http.ClientException(
              'https://private.test/?token=private-fixture',
            );
          }),
        );
        await client.login();
        await expectLater(
          client.torrents.getTorrentsList(),
          throwsA(
            isA<MediaApiException>().having(
              (e) => e.toString(),
              'redacted',
              isNot(contains('private-fixture')),
            ),
          ),
        );
        client.dispose();
      }
    },
  );

  test(
    'timeout and disposal abort ordinary and multipart platform requests',
    () async {
      for (final multipart in [false, true]) {
        final started = Completer<void>();
        final aborted = Completer<void>();
        final monitor = HealthMonitor();
        final transport = RawHttp((request) async {
          expect(request, isA<http.Abortable>());
          final endpoint = request.url.path.split('/').last;
          if (['login', 'version', 'webapiVersion'].contains(endpoint)) {
            final body = switch (endpoint) {
              'version' => 'v5.2.3',
              'webapiVersion' => '2.15.1',
              _ => '',
            };
            return http.StreamedResponse(
              Stream.value(utf8.encode(body)),
              endpoint == 'login' ? 204 : 200,
              headers: endpoint == 'login'
                  ? {'set-cookie': 'SID=fixture; Path=/'}
                  : {},
            );
          }
          started.complete();
          await (request as http.Abortable).abortTrigger;
          aborted.complete();
          throw http.RequestAbortedException(request.url);
        });
        final client = QbittorrentClient(
          config: testConfig,
          httpClient: transport,
          healthSession: monitor.bind(
            IntegrationId.qbittorrent,
            configured: true,
          ),
          requestTimeout: const Duration(milliseconds: 20),
        );
        await client.login();
        final action = multipart
            ? client.torrents.addNewTorrents(
                torrents: const NewTorrents.urls(
                  urls: [
                    'magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                  ],
                ),
              )
            : client.torrents.pauseTorrents(torrents: target);
        final rejected = expectLater(action, throwsA(isA<MediaApiException>()));
        await started.future;
        if (multipart) client.dispose();
        await rejected;
        await aborted.future;
        if (!multipart) {
          expect(
            monitor.read(IntegrationId.qbittorrent).failure,
            HealthFailure.timeout,
          );
        }
        client.dispose();
        monitor.dispose();
      }
    },
  );

  test(
    'invalid torrent inputs and remote cookies never dispatch a write',
    () async {
      var writes = 0;
      final client = QbittorrentClient(
        config: testConfig,
        httpClient: MockClient((request) async {
          final auth = authenticatedResponse(request);
          if (auth != null) return auth;
          writes++;
          return http.Response('', 204);
        }),
      );
      addTearDown(client.dispose);
      await client.login();
      for (final input in [
        const NewTorrents.urls(urls: []),
        const NewTorrents.urls(urls: ['file:///private/config']),
        const NewTorrents.urls(
          urls: ['https://user:password@other.local/file.torrent'],
        ),
        const NewTorrents.urls(
          urls: ['https://other.local/a\nhttps://other.local/b'],
        ),
        const NewTorrents.urls(
          urls: ['https://other.local/a'],
          cookie: 'private-session',
        ),
        NewTorrents.bytes(
          bytes: [
            FileBytes(filename: '../selected.torrent', bytes: Uint8List(1)),
          ],
        ),
        NewTorrents.bytes(
          bytes: [
            FileBytes(
              filename: 'selected.torrent',
              bytes: Uint8List(10 * 1024 * 1024 + 1),
            ),
          ],
        ),
      ]) {
        await expectLater(
          client.torrents.addNewTorrents(torrents: input),
          throwsA(isA<MediaApiException>()),
        );
      }
      expect(writes, 0);
    },
  );
}
