import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final now = DateTime.utc(2026, 9, 5);
const access = 'synthetic_access_token_00000000001';
const refresh = 'synthetic_refresh_token_0000000001';
Map<String, Object?> pair({
  String token = access,
  String refreshToken = refresh,
  bool change = true,
  int expires = 900,
  String id = 'synthetic-user',
  String role = 'admin',
}) => {
  'accessToken': token,
  'refreshToken': refreshToken,
  'expiresIn': expires,
  'user': {
    'id': id,
    'username': 'admin',
    'role': role,
    'mustChangePassword': change,
  },
};

http.Response jsonResponse(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Matcher code(String code) =>
    isA<LarenorServerException>().having((e) => e.code, 'code', code);

class MemorySessions implements ServerSessionPersistence {
  ServerSession? value;
  bool fail = false;
  Completer<void>? writeGate;
  final writes = <ServerSession?>[];
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async {
    final gate = writeGate;
    writeGate = null;
    if (gate != null) await gate.future;
    if (fail) throw const LarenorServerException('storage_failed');
    value = session;
    writes.add(session);
  }
}

void main() {
  test(
    'URL retains reverse proxy prefix and rejects authority/path escapes',
    () {
      expect(
        ServerEndpoint('https://server.test/larenor/')
            .api('/auth/me')
            .toString(),
        'https://server.test/larenor/api/v1/auth/me',
      );
      for (final value in [
        'https://u:p@server.test',
        'https://server.test?q=x',
        'https://server.test/#secret',
        'https://server.test/a/%252e%252e',
        'https://%73erver.test',
        'file:///local',
      ]) {
        expect(() => ServerEndpoint(value), throwsFormatException);
      }
      expect(
        () => ServerEndpoint('https://server.test').api('//evil'),
        throwsA(code('invalid_request')),
      );
    },
  );

  test('session role, expiry and record round trip do not expose secrets', () {
    final session = ServerSession.fromResponse(
      ServerEndpoint('https://server.test'),
      pair(),
      now: now,
    );
    expect(session.user.canAdminister, isFalse);
    expect(session.expiresAt, now.add(const Duration(minutes: 15)));
    expect(session.toString(), isNot(contains(access)));
    final restored = ServerSession.decodeStorage(session.encodeStorage());
    expect(restored.accessToken, access);
    expect(restored.endpoint.baseUrl, 'https://server.test');
    for (final invalid in [
      pair(role: 'root'),
      pair(expires: 0),
      pair(token: 'token\r\nsecret'),
    ]) {
      expect(
        () => ServerSession.fromResponse(
          session.endpoint,
          Map<String, dynamic>.from(invalid),
          now: now,
        ),
        throwsA(code('invalid_response')),
      );
    }
    expect(
      () => ServerSession.decodeStorage('{secret'),
      throwsA(code('invalid_session')),
    );
  });

  test(
    'API login uses JSON body and disables redirects without credential URL',
    () async {
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://server.test/p'),
        clock: () => now,
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://server.test/p/api/v1/auth/login',
          );
          expect(request.followRedirects, isFalse);
          expect(request.headers['authorization'], isNull);
          expect(jsonDecode(request.body), {
            'username': 'admin',
            'password': 'synthetic-password',
            'deviceName': 'Test tablet',
          });
          return jsonResponse(pair());
        }),
      );
      addTearDown(api.close);
      final session = await api.login(
        username: 'admin',
        password: 'synthetic-password',
        deviceName: 'Test tablet',
      );
      expect(session.user.mustChangePassword, isTrue);
    },
  );

  test('API discards raw errors and maps only fixed codes', () async {
    for (final entry in {
      401: 'unauthorized',
      403: 'forbidden',
      409: 'conflict',
      422: 'invalid_request',
      429: 'rate_limited',
      500: 'server_error',
    }.entries) {
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://server.test'),
        client: MockClient(
          (_) async => jsonResponse({
            'error': {'code': access, 'message': refresh},
          }, entry.key),
        ),
      );
      addTearDown(api.close);
      await expectLater(api.me(access), throwsA(code(entry.value)));
    }
  });

  test(
    'API recognizes forced-password block, refuses redirect and HTML',
    () async {
      final responses = [
        jsonResponse({
          'error': {'code': 'password_change_required', 'message': access},
        }, 403),
        http.Response('', 307, headers: {'location': 'https://trap.test'}),
        http.Response('<html>$access</html>', 200),
      ];
      var calls = 0;
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://server.test'),
        client: MockClient((_) async => responses[calls++]),
      );
      addTearDown(api.close);
      await expectLater(
        api.me(access),
        throwsA(code('password_change_required')),
      );
      await expectLater(api.me(access), throwsA(code('connection_failed')));
      await expectLater(api.me(access), throwsA(code('invalid_response')));
      expect(calls, 3);
    },
  );

  test('API bounds JSON bytes, depth, key count and string length', () async {
    Object? nested = 0;
    for (var i = 0; i < 18; i++) {
      nested = {'nested': nested};
    }
    final responses = [
      {'large': 's' * (LarenorServerApi.maxJsonBytes + 1)},
      {'long': 's' * 65537},
      nested,
      {for (var i = 0; i < 10001; i++) 'key$i': i},
    ];
    for (final payload in responses) {
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://server.test'),
        client: MockClient((_) async => jsonResponse(payload)),
      );
      addTearDown(api.close);
      await expectLater(api.me(access), throwsA(code('invalid_response')));
    }
  });

  test('API total timeout does not retry or expose failed payload', () async {
    var calls = 0;
    final pending = Completer<http.Response>();
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://server.test'),
      timeout: const Duration(milliseconds: 20),
      client: MockClient((_) {
        calls++;
        return pending.future;
      }),
    );
    addTearDown(api.close);
    await expectLater(api.refresh(refresh), throwsA(code('timeout')));
    pending.complete(jsonResponse(pair()));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
  });

  test('vault requires v2 privacy validation before use', () {
    expect(
      ServerVault.fromJson({'revision': 0, 'document': null}).snapshot,
      isNull,
    );
    for (final payload in [
      {'revision': -1, 'document': null},
      {
        'revision': 1,
        'document': {
          'version': 1,
          'snapshot': {
            'version': 1,
            'createdAt': now.toIso8601String(),
            'groups': {},
          },
        },
      },
      {
        'revision': 1,
        'document': {
          'version': 1,
          'snapshot': {
            'version': 2,
            'createdAt': now.toIso8601String(),
            'groups': {},
          },
        },
      },
    ]) {
      expect(
        () => ServerVault.fromJson(payload),
        throwsA(code('invalid_response')),
      );
    }
  });

  group('account boundary', () {
    late MemorySessions store;
    late ServerAccountController account;
    late Future<http.Response> Function(http.Request) handler;
    late DateTime clock;
    setUp(() {
      store = MemorySessions();
      clock = now;
      handler = (_) async => jsonResponse(pair());
      account = ServerAccountController(
        store: store,
        clock: () => clock,
        apiFactory: (endpoint) => LarenorServerApi(
          endpoint: endpoint,
          clock: () => clock,
          client: MockClient((request) => handler(request)),
        ),
      );
    });
    tearDown(() {
      account.dispose();
    });

    Future<void> login() => account.signIn(
      baseUrl: 'https://server.test',
      username: 'admin',
      password: 'synthetic-password',
      deviceName: 'Tablet',
    );

    test(
      'first login persists atomically, forces password change before vault',
      () async {
        await login();
        expect(account.session, isNotNull);
        expect(store.value, same(account.session));
        var writes = 0;
        await expectLater(
          account.withSession((api, session) async {
            writes++;
          }),
          throwsA(code('password_change_required')),
        );
        expect(writes, 0);
        handler = (request) async {
          expect(request.url.path, '/api/v1/auth/password');
          expect(request.headers['authorization'], 'Bearer $access');
          return jsonResponse(pair(change: false));
        };
        await account.changePassword(
          currentPassword: 'synthetic-password',
          newPassword: 'synthetic-password-new',
        );
        expect(account.session!.user.canAdminister, isTrue);
        await account.withSession((api, session) async {
          writes++;
        });
        expect(writes, 1);
      },
    );

    test(
      'startup does not trust cached admin role and validates refresh identity',
      () async {
        store.value = ServerSession.fromResponse(
          ServerEndpoint('https://server.test'),
          pair(change: false),
          now: now,
        );
        handler = (request) async {
          expect(request.url.path, '/api/v1/auth/me');
          expect(account.session, isNull);
          return jsonResponse({
            'user': pair(role: 'member', change: false)['user'],
          });
        };
        await account.initialize();
        expect(account.session!.user.canAdminister, isFalse);
        expect(account.initialized, isTrue);
      },
    );

    test('concurrent expiry callers share one refresh rotation', () async {
      handler = (_) async => jsonResponse(pair(change: false));
      await login();
      clock = now.add(const Duration(minutes: 16));
      final gate = Completer<http.Response>();
      var calls = 0;
      handler = (_) {
        calls++;
        return gate.future;
      };
      final first = account.ensureSession();
      final second = account.ensureSession();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      gate.complete(
        jsonResponse(
          pair(
            change: false,
            refreshToken: 'synthetic_rotated_refresh_00000001',
          ),
        ),
      );
      final results = await Future.wait([first, second]);
      expect(results[0], same(results[1]));
      expect(store.value!.refreshToken, 'synthetic_rotated_refresh_00000001');
    });

    for (final expired in [false, true]) {
      test(
        'offline startup preserves stored tokens (expired=$expired)',
        () async {
          final stored = ServerSession.fromResponse(
            ServerEndpoint('https://server.test'),
            pair(change: false),
            now: now,
          );
          store.value = stored;
          if (expired) clock = now.add(const Duration(hours: 1));
          var refreshCalls = 0;
          handler = (request) async {
            if (request.url.path.endsWith('/refresh')) refreshCalls++;
            throw http.ClientException('synthetic offline');
          };
          await account.initialize();
          expect(account.session, isNull);
          expect(account.initialized, isFalse);
          expect(account.failure, 'connection_failed');
          expect(store.value, same(stored));
          expect(refreshCalls, 0);
          handler = (request) async {
            if (request.url.path.endsWith('/health')) {
              return jsonResponse({
                'service': 'larenor-server',
                'apiVersion': 1,
              });
            }
            if (request.url.path.endsWith('/me')) {
              return jsonResponse({'user': pair(change: false)['user']});
            }
            refreshCalls++;
            return jsonResponse(pair(change: false));
          };
          await account.initialize();
          expect(account.session, isNotNull);
          expect(account.initialized, isTrue);
          expect(refreshCalls, expired ? 1 : 0);
        },
      );
    }

    test(
      'cancel pending login drops a late response and writes no session',
      () async {
        final gate = Completer<http.Response>();
        handler = (_) => gate.future;
        final signingIn = login();
        await Future<void>.delayed(Duration.zero);
        final oldGeneration = account.generation;
        await account.cancelPending();
        gate.complete(jsonResponse(pair()));
        await signingIn;
        expect(account.isCurrent(oldGeneration), isFalse);
        expect(account.working, isFalse);
        expect(account.session, isNull);
        expect(store.value, isNull);
        expect(store.writes.whereType<ServerSession>(), isEmpty);
      },
    );

    test(
      'cancel pending password change clears old and late replacement tokens',
      () async {
        await login();
        final gate = Completer<http.Response>();
        handler = (_) => gate.future;
        final changing = account.changePassword(
          currentPassword: 'old-synthetic',
          newPassword: 'new-synthetic',
        );
        await Future<void>.delayed(Duration.zero);
        expect(account.working, isTrue);
        await account.cancelPending();
        gate.complete(jsonResponse(pair(change: false)));
        await changing;
        expect(account.session, isNull);
        expect(store.value, isNull);
        expect(account.failure, 'cancelled');
      },
    );

    test(
      'cancel readonly startup preserves a session for an explicit retry',
      () async {
        final stored = ServerSession.fromResponse(
          ServerEndpoint('https://server.test'),
          pair(change: false),
          now: now,
        );
        store.value = stored;
        final gate = Completer<http.Response>();
        handler = (_) => gate.future;
        final loading = account.initialize();
        await Future<void>.delayed(Duration.zero);
        await account.cancelPending();
        gate.complete(jsonResponse({'user': pair(change: false)['user']}));
        await loading;
        expect(store.value, same(stored));
        expect(account.session, isNull);
        expect(account.initialized, isFalse);
        expect(account.working, isFalse);
      },
    );

    test(
      'failed refresh clears session and is never automatically retried',
      () async {
        handler = (_) async => jsonResponse(pair(change: false));
        await login();
        clock = now.add(const Duration(hours: 1));
        var calls = 0;
        handler = (_) async {
          calls++;
          throw http.ClientException('secret $access');
        };
        await expectLater(
          account.ensureSession(),
          throwsA(code('connection_failed')),
        );
        await expectLater(
          account.ensureSession(),
          throwsA(code('unauthorized')),
        );
        expect(account.session, isNull);
        expect(store.value, isNull);
        expect(calls, 1);
      },
    );

    test(
      'logout before a late login response never persists the account',
      () async {
        final gate = Completer<http.Response>();
        handler = (_) => gate.future;
        final signingIn = login();
        await Future<void>.delayed(Duration.zero);
        await account.signOut();
        gate.complete(jsonResponse(pair()));
        await signingIn;
        expect(account.session, isNull);
        expect(store.value, isNull);
        expect(store.writes.whereType<ServerSession>(), isEmpty);
      },
    );

    test('logout during secure-store write follows it with a clear', () async {
      final gate = Completer<void>();
      store.writeGate = gate;
      final signingIn = login();
      await Future<void>.delayed(Duration.zero);
      final signingOut = account.signOut();
      gate.complete();
      await Future.wait([signingIn, signingOut]);
      expect(account.session, isNull);
      expect(store.value, isNull);
      expect(store.writes.last, isNull);
    });

    test(
      'revoked action response clears account and write is not retried',
      () async {
        handler = (_) async => jsonResponse(pair(change: false));
        await login();
        var calls = 0;
        handler = (_) async {
          calls++;
          return jsonResponse({}, 401);
        };
        await expectLater(
          account.withSession(
            (api, session) => api.readVault(session.accessToken),
          ),
          throwsA(code('unauthorized')),
        );
        expect(account.session, isNull);
        expect(calls, 1);
      },
    );

    test(
      'storage failure keeps credentials out of UI and refuses signed-in state',
      () async {
        store.fail = true;
        await login();
        expect(account.session, isNull);
        expect(account.failure, 'storage_failed');
      },
    );

    test(
      'refresh returning a different user cannot replace the active account',
      () async {
        store.value = ServerSession.fromResponse(
          ServerEndpoint('https://server.test'),
          pair(change: false),
          now: now,
        );
        handler = (_) async =>
            jsonResponse({'user': pair(id: 'different-user')['user']});
        await account.initialize();
        expect(account.session, isNull);
        expect(account.failure, 'invalid_response');
        expect(store.value, isNull);
      },
    );
  });
}
