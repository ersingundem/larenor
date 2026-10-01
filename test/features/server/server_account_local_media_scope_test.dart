import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final _now = DateTime.utc(2026, 10, 1);

ServerSession _stored({
  bool context = true,
  bool family = true,
  bool pending = false,
  bool passwordRequired = false,
}) => ServerSession(
  endpoint: ServerEndpoint('https://owned-core.invalid'),
  accessToken: 'synthetic_access_token_00000000001',
  refreshToken: 'synthetic_refresh_token_0000000001',
  expiresAt: _now.add(const Duration(hours: 1)),
  context: context
      ? ServerContext.fromJson({
          'schemaVersion': 1,
          'coreId': 'a' * 32,
          'homeId': 'b' * 32,
        })
      : null,
  sessionFamilyId: family ? 'd' * 32 : null,
  authMutationPending: pending,
  user: ServerUser(
    id: 'c' * 32,
    username: 'admin',
    role: ServerRole.admin,
    mustChangePassword: passwordRequired,
  ),
);

final class _Store implements ServerSessionPersistence {
  _Store(this.value);
  ServerSession? value;
  Completer<void>? writeGate;
  Completer<ServerSession?>? readGate;

  @override
  Future<ServerSession?> read() async => readGate?.future ?? value;

  @override
  Future<void> write(ServerSession? session) async {
    final gate = writeGate;
    writeGate = null;
    if (gate != null) await gate.future;
    value = session == null
        ? null
        : ServerSession.decodeStorage(session.encodeStorage());
  }
}

ServerAccountController _account(
  _Store store,
  Future<http.Response> Function(http.Request) reply,
) => ServerAccountController(
  store: store,
  clock: () => _now,
  apiFactory: (endpoint) =>
      LarenorServerApi(endpoint: endpoint, client: MockClient(reply)),
);

void main() {
  test(
    'offline startup exposes only a local selector and no API session',
    () async {
      final store = _Store(_stored());
      final calls = <String>[];
      final account = _account(store, (request) async {
        calls.add('${request.method} ${request.url.path}');
        throw http.ClientException('owned offline fixture');
      });
      addTearDown(account.dispose);
      await account.initialize();
      final scope = account.localMediaScope!;
      expect(
        [scope.coreId, scope.homeId, scope.accountId, scope.sessionFamilyId],
        ['a' * 32, 'b' * 32, 'c' * 32, 'd' * 32],
      );
      expect(scope.toString(), 'ServerLocalMediaScope');
      expect(account.session, isNull);
      expect(account.initialized, isFalse);
      expect(store.value?.authMutationPending, isFalse);
      await expectLater(
        account.withSession((api, session) async => true),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'unauthorized',
          ),
        ),
      );
      expect(calls, ['GET /api/v1/auth/me']);
    },
  );

  for (final missing in ['context', 'family', 'pending', 'password']) {
    test('unsafe cached $missing never exposes local scope', () async {
      final store = _Store(
        _stored(
          context: missing != 'context',
          family: missing != 'family',
          pending: missing == 'pending',
          passwordRequired: missing == 'password',
        ),
      );
      final account = _account(store, (_) async {
        throw http.ClientException('owned offline fixture');
      });
      addTearDown(account.dispose);
      await account.initialize();
      expect(account.localMediaScope, isNull);
      expect(account.session, isNull);
    });
  }

  test('logout removes offline selector before persistence finishes', () async {
    final store = _Store(_stored());
    final account = _account(store, (_) async {
      throw http.ClientException('owned offline fixture');
    });
    addTearDown(account.dispose);
    await account.initialize();
    expect(account.localMediaScope, isNotNull);
    final gate = Completer<void>();
    store.writeGate = gate;
    final logout = account.signOut();
    expect(account.localMediaScope, isNull);
    gate.complete();
    await logout;
    expect(store.value, isNull);
    expect(account.localMediaScope, isNull);
  });

  test('unconfirmed refresh cannot resume cached offline scope', () async {
    final store = _Store(_stored());
    final calls = <String>[];
    final account = _account(store, (request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'error': {'code': 'unauthorized'},
          }),
          401,
          headers: {'content-type': 'application/json'},
        );
      }
      throw http.ClientException('owned uncertain refresh fixture');
    });
    addTearDown(account.dispose);
    await account.initialize();
    expect(account.localMediaScope, isNull);
    expect(account.session, isNull);
    expect(store.value?.authMutationPending, isTrue);
    expect(calls, ['GET /api/v1/auth/me', 'POST /api/v1/auth/refresh']);
  });

  test('authoritative rejection clears cached offline scope', () async {
    final store = _Store(_stored());
    final account = _account(
      store,
      (_) async => http.Response(
        jsonEncode({
          'error': {'code': 'forbidden'},
        }),
        403,
        headers: {'content-type': 'application/json'},
      ),
    );
    addTearDown(account.dispose);
    await account.initialize();
    expect(account.localMediaScope, isNull);
    expect(store.value, isNull);
  });

  test(
    'late secure profile read cannot resurrect a signed-out scope',
    () async {
      final store = _Store(_stored());
      final gate = Completer<ServerSession?>();
      store.readGate = gate;
      final calls = <String>[];
      final account = _account(store, (request) async {
        calls.add(request.url.path);
        throw http.ClientException('owned offline fixture');
      });
      addTearDown(account.dispose);
      final initialization = account.initialize();
      final logout = account.signOut();
      gate.complete(_stored());
      await Future.wait([initialization, logout]);
      expect(account.localMediaScope, isNull);
      expect(account.session, isNull);
      expect(store.value, isNull);
      expect(calls, ['/api/v1/auth/logout']);
    },
  );
}
