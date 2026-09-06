import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
// The pinned plugin's public platform seam, with no real Keychain/Keystore.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'server_account_test.dart' show pair, contextJson, jsonResponse, now;

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _key = SecureServerSessionStore.key;

enum _Fault { none, before, after }

class _Platform {
  final values = <String, String>{
    'ha_token': 'retained-synthetic-ha',
    'settings_pin': 'retained-synthetic-pin',
    'wellbeing_private_v1': 'retained-synthetic-private',
  };
  final calls = <String>[];
  _Fault writeFault = _Fault.none,
      deleteFault = _Fault.none,
      readFault = _Fault.none;
  Future<void> Function(String method)? before;

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments as Map;
    final key = args['key'] as String?;
    calls.add('${call.method}:$key');
    await before?.call(call.method);
    final fault = key != _key
        ? _Fault.none
        : call.method == 'write'
        ? writeFault
        : call.method == 'delete'
        ? deleteFault
        : call.method == 'read'
        ? readFault
        : _Fault.none;
    void fail() => throw PlatformException(
      code: 'synthetic-platform-fault',
      message: 'private platform payload',
    );
    if (fault == _Fault.before) fail();
    final Object? result;
    switch (call.method) {
      case 'read':
        result = values[key];
      case 'write':
        values[key!] = args['value'] as String;
        result = null;
      case 'delete':
        values.remove(key);
        result = null;
      default:
        throw StateError('Unexpected secure platform method');
    }
    if (fault == _Fault.after) fail();
    return result;
  }
}

class _Server {
  final calls = <String>[];
  final logoutFamilies = <String>[];
  Future<http.Response> Function(http.Request)? reply;
  Future<http.Response> handle(http.Request request) async {
    calls.add(request.url.path);
    if (request.url.path.endsWith('/auth/logout')) {
      logoutFamilies.add(
        (jsonDecode(request.body) as Map)['refreshToken'] as String,
      );
    }
    if (reply case final handler?) return handler(request);
    return normal(request);
  }

  http.Response normal(http.Request request) {
    return switch (request.url.path) {
      '/api/v1/auth/login' => jsonResponse(pair(change: false)),
      '/api/v1/auth/me' => jsonResponse({'user': pair(change: false)['user']}),
      '/api/v1/context' => jsonResponse(contextJson()),
      '/api/v1/auth/logout' => http.Response('', 204),
      _ => throw StateError('Unexpected synthetic request'),
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FlutterSecureStoragePlatform previous;
  late _Platform platform;
  late _Server server;
  final accounts = <ServerAccountController>[];
  ServerAccountController create() {
    final account = ServerAccountController(
      store: SecureServerSessionStore(storage: const FlutterSecureStorage()),
      clock: () => now,
      apiFactory: (endpoint) => LarenorServerApi(
        endpoint: endpoint,
        clock: () => now,
        client: MockClient(server.handle),
      ),
    );
    accounts.add(account);
    return account;
  }

  Future<void> login(ServerAccountController account) => account.signIn(
    baseUrl: 'https://core.test',
    username: 'admin',
    password: 'synthetic-password',
    deviceName: 'Synthetic tablet',
  );
  setUp(() {
    platform = _Platform();
    server = _Server();
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, platform.handle);
  });
  tearDown(() {
    for (final account in accounts) {
      account.dispose();
    }
    accounts.clear();
    FlutterSecureStoragePlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('failed durable delete and remote logout cannot revive saved tokens on restart', () async {
    final account = create();
    await login(account);
    expect(account.context, isNotNull);
    final unrelated = Map<String, String>.of(platform.values)..remove(_key);
    platform.deleteFault = _Fault.before;
    server.reply = (_) async => throw http.ClientException('synthetic offline');
    await account.signOut();
    expect(account.session, isNull);
    expect(account.failure, 'storage_failed');
    platform.deleteFault = _Fault.none;
    server.reply = null;
    server.calls.clear();
    final restarted = create();
    await restarted.initialize();
    expect(restarted.session, isNull);
    expect(restarted.failure, 'invalid_session');
    expect(server.calls, isEmpty);
    expect(Map<String, String>.of(platform.values)..remove(_key), unrelated);
    expect(platform.calls, isNot(contains('deleteAll:null')));
  });

  for (final write in _Fault.values) {
    for (final delete in _Fault.values) {
      test(
        'write ${write.name}, delete ${delete.name}: durable outcome and failure are honest after remote loss',
        () async {
          final account = create();
          await login(account);
          final unrelated = Map<String, String>.of(platform.values)
            ..remove(_key);
          platform.writeFault = write;
          platform.deleteFault = delete;
          server.reply = (_) async =>
              throw http.ClientException('synthetic offline');
          await account.signOut();
          expect(account.session, isNull);
          expect(account.context, isNull);
          expect(
            account.failure,
            write == _Fault.none && delete == _Fault.none
                ? 'logout_not_confirmed'
                : 'storage_failed',
          );
          expect(account.failure, isNot(contains('private')));
          expect(server.logoutFamilies, hasLength(1));
          await expectLater(
            account.ensureSession(),
            throwsA(isA<LarenorServerException>()),
          );
          expect(
            Map<String, String>.of(platform.values)..remove(_key),
            unrelated,
          );
          // No system can persist a logout if BOTH disk effects and remote
          // revocation fail. Assert this limitation rather than fake a guarantee.
          final noDurableEffect =
              write == _Fault.before && delete == _Fault.before;
          platform.writeFault = platform.deleteFault = _Fault.none;
          server.reply = null;
          server.calls.clear();
          final restarted = create();
          await restarted.initialize();
          if (noDurableEffect) {
            expect(restarted.session, isNotNull);
            expect(server.calls, ['/api/v1/auth/me', '/api/v1/context']);
          } else {
            expect(restarted.session, isNull);
            expect(server.calls, isEmpty);
          }
        },
      );
    }
  }

  test(
    'a successful remote revoke still runs when both local mutations fail',
    () async {
      final account = create();
      await login(account);
      platform.writeFault = platform.deleteFault = _Fault.before;
      await account.signOut();
      expect(account.failure, 'storage_failed');
      expect(server.logoutFamilies, hasLength(1));
      platform.writeFault = platform.deleteFault = _Fault.none;
      server.calls.clear();
      server.reply = (_) async => jsonResponse({}, 401);
      final restarted = create();
      await restarted.initialize();
      expect(restarted.session, isNull);
      expect(server.calls, isNot(contains('/api/v1/context')));
    },
  );

  test('pending initialize logout reads and retires the durable record without publishing it', () async {
    final original = create();
    await login(original);
    final entered = Completer<void>(), release = Completer<void>();
    var held = false;
    platform.before = (method) async {
      if (method == 'read' && !held) {
        held = true;
        entered.complete();
        await release.future;
      }
    };
    final account = create();
    final initializing = account.initialize();
    await entered.future;
    expect(account.session, isNull);
    platform.deleteFault = _Fault.before;
    server.calls.clear();
    server.reply = (_) async => throw http.ClientException('synthetic offline');
    await account.signOut();
    expect(server.calls, ['/api/v1/auth/logout']);
    release.complete();
    await initializing;
    expect(account.session, isNull);
    expect(account.failure, 'storage_failed');
    platform.before = null;
    platform.deleteFault = _Fault.none;
    server.reply = null;
    server.calls.clear();
    final restarted = create();
    await restarted.initialize();
    expect(restarted.session, isNull);
    expect(server.calls, isEmpty);
  });

  test(
    'logout serializes after an already-dispatched authentication write',
    () async {
      final account = create();
      final entered = Completer<void>(), release = Completer<void>();
      var held = false;
      platform.before = (method) async {
        if (method == 'write' && !held) {
          held = true;
          entered.complete();
          await release.future;
        }
      };
      final signingIn = login(account);
      await entered.future;
      expect(account.hasPendingContext, isTrue);
      final signingOut = account.signOut();
      release.complete();
      await Future.wait([signingIn, signingOut]);
      expect(account.session, isNull);
      expect(platform.values.containsKey(_key), isFalse);
      expect(server.calls, isNot(contains('/api/v1/context')));
      final mutations = platform.calls
          .where((x) => x.startsWith('write:') || x.startsWith('delete:'))
          .toList();
      expect(mutations, ['write:$_key', 'write:$_key', 'delete:$_key']);
    },
  );

  test('new login after logout intent began survives old delete and remote failure', () async {
    final account = create();
    await login(account);
    final originalFamily = account.session!.refreshToken;
    final entered = Completer<void>(), release = Completer<void>();
    var held = false;
    platform.before = (method) async {
      if (method == 'write' && !held) {
        held = true;
        entered.complete();
        await release.future;
      }
    };
    final signingOut = account.signOut();
    await entered.future;
    final lateLogout = Completer<http.Response>();
    server.reply = (request) async {
      if (request.url.path.endsWith('/auth/logout')) return lateLogout.future;
      if (request.url.path.endsWith('/auth/login')) {
        return jsonResponse(
          pair(
            change: false,
            token: 'replacement_access_00000000000001',
            refreshToken: 'replacement_refresh_000000000001',
          ),
        );
      }
      return server.normal(request);
    };
    final signingIn = login(account);
    release.complete();
    await signingIn;
    final replacement = account.session!;
    expect(replacement.refreshToken == originalFamily, isFalse);
    lateLogout.completeError(http.ClientException('synthetic old logout loss'));
    await signingOut;
    expect(account.session, same(replacement));
    expect(account.failure, isNull);
    expect(server.logoutFamilies, [originalFamily]);
    expect(
      ServerSession.decodeStorage(platform.values[_key]!).refreshToken,
      replacement.refreshToken,
    );
    expect(platform.calls.where((x) => x == 'delete:$_key'), isEmpty);
  });

  test('double logout never restores an intent or leaves the previous pair reusable', () async {
    final account = create();
    await login(account);
    final originalFamily = account.session!.refreshToken;
    final entered = Completer<void>(), release = Completer<void>();
    var held = false;
    platform.before = (method) async {
      if (method == 'write' && !held) {
        held = true;
        entered.complete();
        await release.future;
      }
    };
    final first = account.signOut();
    await entered.future;
    final second = account.signOut();
    release.complete();
    await Future.wait([first, second]);
    expect(account.session, isNull);
    expect(account.failure, isNull);
    expect(platform.values.containsKey(_key), isFalse);
    expect(server.logoutFamilies, everyElement(originalFamily));
    expect(server.logoutFamilies, isNotEmpty);
  });

  test('unknown record read failure still attempts local deletion without leaking platform errors', () async {
    final account = create();
    platform.readFault = _Fault.before;
    await account.signOut();
    expect(account.failure, 'storage_failed');
    expect(platform.calls, ['read:$_key', 'delete:$_key']);
    expect(server.calls, isEmpty);
  });
}
