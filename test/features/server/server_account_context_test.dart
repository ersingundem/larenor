import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final _now = DateTime.utc(2026, 9, 5, 12);
final _endpoint = ServerEndpoint('https://core.test');
final _context = ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
});

ServerSession _session(int version, {bool passwordRequired = false}) =>
    ServerSession(
      endpoint: _endpoint,
      accessToken: 'synthetic_access_${version.toString().padLeft(20, '0')}',
      refreshToken: 'synthetic_refresh_${version.toString().padLeft(20, '0')}',
      expiresAt: _now.add(Duration(minutes: version * 20)),
      user: ServerUser(
        id: 'synthetic-user',
        username: 'admin',
        role: ServerRole.admin,
        mustChangePassword: passwordRequired,
      ),
    );

class _Store implements ServerSessionPersistence {
  ServerSession? value;
  final writes = <ServerSession?>[];
  bool failIntent = false;
  bool failCandidate = false;
  bool failBound = false;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async {
    if ((failIntent && session?.authMutationPending == true) ||
        (failCandidate &&
            session != null &&
            !session.authMutationPending &&
            session.context == null) ||
        (failBound && session?.context != null)) {
      throw const LarenorServerException('storage_failed');
    }
    // Exercise the real single-record encoding, including restart semantics.
    value = session == null
        ? null
        : ServerSession.decodeStorage(session.encodeStorage());
    writes.add(value);
  }
}

class _Api extends LarenorServerApi {
  _Api() : super(endpoint: _endpoint);
  final calls = <String>[];
  final usedRefresh = <String>[];
  final usedContext = <String>[];
  ServerSession next = _session(1);
  Future<ServerContext> Function()? contextReply;
  Future<ServerSession> Function()? authReply;

  @override
  Future<void> health() async {
    calls.add('health');
  }

  @override
  Future<ServerUser> me(String accessToken) async {
    calls.add('me');
    return next.user;
  }

  @override
  Future<ServerSession> login({
    required String username,
    required String password,
    required String deviceName,
  }) async {
    calls.add('login');
    return authReply == null ? next : authReply!();
  }

  @override
  Future<ServerSession> refresh(String refreshToken) async {
    calls.add('refresh');
    usedRefresh.add(refreshToken);
    return authReply == null ? next : authReply!();
  }

  @override
  Future<ServerSession> changePassword({
    required String accessToken,
    required String currentPassword,
    required String newPassword,
  }) async {
    calls.add('password');
    return authReply == null ? next : authReply!();
  }

  @override
  Future<ServerContext> context(String accessToken) async {
    calls.add('context');
    usedContext.add(accessToken);
    return contextReply == null ? _context : contextReply!();
  }

  @override
  Future<void> logout(ServerSession session) async {
    calls.add('logout');
  }

  @override
  void close() {}
}

void main() {
  late _Store store;
  late _Api api;
  late ServerAccountController account;
  late DateTime clock;
  setUp(() {
    store = _Store();
    api = _Api();
    clock = _now;
    account = ServerAccountController(
      store: store,
      apiFactory: (_) => api,
      clock: () => clock,
    );
  });
  tearDown(() => account.dispose());

  Future<void> login() => account.signIn(
    baseUrl: _endpoint.baseUrl,
    username: 'admin',
    password: 'Synthetic password',
    deviceName: 'Test tablet',
  );

  test('successful login persists pending tokens before context and publishes only a bound record', () async {
    final gate = Completer<ServerContext>();
    api.contextReply = () => gate.future;
    final pending = login();
    await Future<void>.delayed(Duration.zero);
    expect(api.calls, ['login', 'context']);
    expect(store.value?.accessToken, api.next.accessToken);
    expect(store.value?.context, isNull);
    expect(account.session, isNull);
    expect(account.context, isNull);
    expect(account.hasPendingContext, isTrue);
    gate.complete(_context);
    await pending;
    expect(account.session?.context, _context);
    expect(account.context, _context);
    expect(store.value?.context, _context);
    expect(account.hasPendingContext, isFalse);
  });

  for (final operation in ['login', 'refresh', 'password']) {
    test(
      '$operation success then context failure preserves new tokens; manual retry is GET only',
      () async {
        if (operation != 'login') {
          api.next = _session(1, passwordRequired: operation == 'password');
          await login();
          api.calls.clear();
          api.next = _session(2);
        }
        api.contextReply = () =>
            Future.error(const LarenorServerException('timeout'));
        if (operation == 'login') {
          await login();
        } else if (operation == 'refresh') {
          clock = _now.add(const Duration(minutes: 21));
          await expectLater(
            account.ensureSession(),
            throwsA(isA<LarenorServerException>()),
          );
        } else {
          await account.changePassword(
            currentPassword: 'Synthetic old',
            newPassword: 'Synthetic new',
          );
        }
        expect(account.session, isNull);
        expect(account.hasPendingContext, isTrue);
        expect(account.initialized, isTrue);
        expect(store.value?.refreshToken, api.next.refreshToken);
        expect(store.value?.authMutationPending, isFalse);
        final before = List<String>.of(api.calls);
        await account.initialize();
        await expectLater(
          account.ensureSession(),
          throwsA(isA<LarenorServerException>()),
        );
        expect(
          api.calls,
          before,
          reason: 'A pending context never starts automatic auth or GET retry.',
        );
        api.contextReply = null;
        await account.retryContext();
        expect(api.calls, [...before, 'context']);
        expect(api.usedContext.last, api.next.accessToken);
        expect(account.context, _context);
        expect(account.session?.refreshToken, api.next.refreshToken);
      },
    );
  }

  test('restart revalidates stored pending candidate without replaying its auth POST', () async {
    api.contextReply = () =>
        Future.error(const LarenorServerException('connection_failed'));
    await login();
    account.dispose();
    api.calls.clear();
    api.contextReply = null;
    account = ServerAccountController(
      store: store,
      apiFactory: (_) => api,
      clock: () => clock,
    );
    await account.initialize();
    expect(api.calls, ['me', 'context']);
    expect(account.context, _context);
  });

  for (final destination in ['pending', 'same_context', 'other_context']) {
    test(
      'late unauthorized cannot reject rotated $destination session',
      () async {
        await login();
        final response = Completer<void>();
        final started = Completer<void>();
        final oldRequest = account.withSession((_, _) {
          started.complete();
          return response.future;
        });
        await started.future;
        final oldResult = expectLater(
          oldRequest,
          throwsA(
            isA<LarenorServerException>().having(
              (error) => error.code,
              'code',
              'cancelled',
            ),
          ),
        );
        clock = _now.add(const Duration(minutes: 21));
        api.next = _session(2);
        final nextContext = destination == 'other_context'
            ? ServerContext.fromJson({
                'schemaVersion': 1,
                'coreId': 'c' * 32,
                'homeId': 'd' * 32,
              })
            : _context;
        final contextGate = Completer<ServerContext>();
        api.contextReply = () => destination == 'pending'
            ? contextGate.future
            : Future.value(nextContext);
        final rotation = account.ensureSession();
        await Future<void>.delayed(Duration.zero);
        if (destination != 'pending') await rotation;
        response.completeError(const LarenorServerException('unauthorized'));
        await oldResult;
        expect(store.value?.refreshToken, api.next.refreshToken);
        expect(store.value?.authMutationPending, isFalse);
        expect(account.failure, isNull);
        if (destination == 'pending') {
          expect(account.hasPendingContext, isTrue);
          contextGate.complete(nextContext);
          await rotation;
        }
        expect(account.context, nextContext);
        expect(account.session?.refreshToken, api.next.refreshToken);
      },
    );
  }

  test(
    'first-password session never calls context; ready actions stay denied',
    () async {
      api.next = _session(1, passwordRequired: true);
      await login();
      expect(api.calls, ['login']);
      expect(account.session?.user.mustChangePassword, isTrue);
      expect(account.hasPendingContext, isFalse);
      await expectLater(
        account.withSession((_, _) async => fail('Ready action invoked')),
        throwsA(isA<LarenorServerException>()),
      );
    },
  );

  test(
    '404-compatible context failure remains pending and does not retry auth',
    () async {
      api.contextReply = () =>
          Future.error(const LarenorServerException('server_error'));
      await login();
      await account.retryContext();
      expect(api.calls, ['login', 'context', 'context']);
      expect(account.session, isNull);
      expect(account.hasPendingContext, isTrue);
    },
  );

  test('cancel after auth success preserves candidate, ignores late context, and retries explicitly', () async {
    final gate = Completer<ServerContext>();
    api.contextReply = () => gate.future;
    final pending = login();
    await Future<void>.delayed(Duration.zero);
    await account.cancelPending();
    expect(store.value?.refreshToken, api.next.refreshToken);
    expect(account.hasPendingContext, isTrue);
    gate.complete(_context);
    await pending;
    expect(account.context, isNull);
    api.contextReply = null;
    await account.retryContext();
    expect(account.context, _context);
    expect(api.calls.where((c) => c == 'login'), hasLength(1));
  });

  test('logout retires a context callback and removes both stored and pending credentials', () async {
    final gate = Completer<ServerContext>();
    api.contextReply = () => gate.future;
    final pending = login();
    await Future<void>.delayed(Duration.zero);
    await account.signOut();
    gate.complete(_context);
    await pending;
    expect(store.value, isNull);
    expect(account.session, isNull);
    expect(account.hasPendingContext, isFalse);
    expect(api.calls.where((c) => c == 'logout'), hasLength(1));
  });

  test('intent persistence failure prevents refresh POST entirely', () async {
    await login();
    api.calls.clear();
    store.failIntent = true;
    clock = _now.add(const Duration(minutes: 21));
    await expectLater(
      account.ensureSession(),
      throwsA(isA<LarenorServerException>()),
    );
    expect(api.calls, isEmpty);
  });

  test(
    'unknown rotation leaves durable intent; restart never reuses old refresh',
    () async {
      await login();
      clock = _now.add(const Duration(minutes: 21));
      api.authReply = () =>
          Future.error(const LarenorServerException('timeout'));
      await expectLater(
        account.ensureSession(),
        throwsA(isA<LarenorServerException>()),
      );
      expect(store.value?.authMutationPending, isTrue);
      account.dispose();
      api.calls.clear();
      account = ServerAccountController(
        store: store,
        apiFactory: (_) => api,
        clock: () => clock,
      );
      await account.initialize();
      expect(api.calls, isEmpty);
      expect(account.session, isNull);
    },
  );

  test('new token write failure keeps intent until explicit candidate save and GET retry', () async {
    await login();
    clock = _now.add(const Duration(minutes: 21));
    api.next = _session(2);
    store.failCandidate = true;
    await expectLater(
      account.ensureSession(),
      throwsA(isA<LarenorServerException>()),
    );
    expect(store.value?.authMutationPending, isTrue);
    expect(account.context, isNull);
    expect(account.hasPendingContext, isTrue);
    store.failCandidate = false;
    final before = api.calls.length;
    await account.retryContext();
    expect(api.calls.skip(before), ['context']);
    expect(store.value?.refreshToken, api.next.refreshToken);
    expect(store.value?.authMutationPending, isFalse);
    expect(account.context, _context);
  });

  test('failed bound-record save keeps the saved candidate private until explicit GET retry', () async {
    store.failBound = true;
    await login();
    expect(account.context, isNull);
    expect(account.session, isNull);
    expect(account.hasPendingContext, isTrue);
    expect(store.value?.context, isNull);
    expect(store.value?.refreshToken, api.next.refreshToken);
    store.failBound = false;
    await account.retryContext();
    expect(api.calls, ['login', 'context', 'context']);
    expect(account.context, _context);
  });

  test('candidate context unauthorized requires fresh sign-in without replaying auth', () async {
    api.contextReply = () =>
        Future.error(const LarenorServerException('unauthorized'));
    await login();
    expect(account.session, isNull);
    expect(account.hasPendingContext, isFalse);
    expect(store.value, isNull);
    await account.retryContext();
    expect(api.calls, ['login', 'context']);
    expect(account.failure, 'unauthorized');
  });

  test(
    'current authenticated request unauthorized still clears the bound session',
    () async {
      await login();
      await expectLater(
        account.withSession(
          (_, _) =>
              Future<void>.error(const LarenorServerException('unauthorized')),
        ),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'unauthorized',
          ),
        ),
      );
      expect(account.session, isNull);
      expect(store.value, isNull);
    },
  );

  for (final failure in [
    'timeout',
    'invalid_response',
    'connection_failed',
    'server_error',
  ]) {
    test('uncertain password $failure leaves a restart-safe intent', () async {
      await login();
      api.authReply = () => Future.error(LarenorServerException(failure));
      await account.changePassword(
        currentPassword: 'Synthetic old',
        newPassword: 'Synthetic new',
      );
      expect(account.session, isNull);
      expect(account.hasPendingContext, isFalse);
      expect(store.value?.authMutationPending, isTrue);
      account.dispose();
      api.calls.clear();
      account = ServerAccountController(
        store: store,
        apiFactory: (_) => api,
        clock: () => clock,
      );
      await account.initialize();
      expect(api.calls, isEmpty);
      expect(account.session, isNull);
    });
  }

  for (final failure in [
    'invalid_request',
    'rate_limited',
    'forbidden',
    'busy',
  ]) {
    test(
      'definitive password $failure restores the unchanged bound record',
      () async {
        await login();
        final previous = account.session;
        api.authReply = () => Future.error(LarenorServerException(failure));
        await account.changePassword(
          currentPassword: 'Synthetic old',
          newPassword: 'Synthetic new',
        );
        expect(account.session, same(previous));
        expect(store.value?.authMutationPending, isFalse);
        expect(store.value?.context, _context);
        expect(api.calls, ['login', 'context', 'password']);
      },
    );
  }

  test('intent persistence failure prevents password POST entirely', () async {
    await login();
    api.calls.clear();
    store.failIntent = true;
    await account.changePassword(
      currentPassword: 'Synthetic old',
      newPassword: 'Synthetic new',
    );
    expect(api.calls, isEmpty);
    expect(store.value?.authMutationPending, isFalse);
  });

  test('strict v2 record round trip and legacy v1 have no implicit context authority', () {
    final raw = jsonDecode(_session(1).encodeStorage()) as Map<String, dynamic>;
    expect(raw['version'], 2);
    expect(raw['context'], isNull);
    expect(raw['authMutationPending'], isFalse);
    raw['version'] = 1;
    raw.remove('context');
    raw.remove('authMutationPending');
    final legacy = ServerSession.decodeStorage(jsonEncode(raw));
    expect(legacy.context, isNull);
    expect(legacy.authMutationPending, isFalse);
    raw['version'] = 2;
    raw['context'] = _context.toJson();
    raw['authMutationPending'] = 'false';
    expect(
      () => ServerSession.decodeStorage(jsonEncode(raw)),
      throwsA(isA<LarenorServerException>()),
    );
  });
}
