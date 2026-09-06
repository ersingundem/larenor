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
  _Fault writeFault = _Fault.none, deleteFault = _Fault.none;
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
        : _Fault.none;
    void fail() => throw PlatformException(
      code: 'synthetic-platform-fault', message: 'private platform payload',
    );
    if (fault == _Fault.before) fail();
    final Object? result;
    switch (call.method) {
      case 'read': result = values[key];
      case 'write': values[key!] = args['value'] as String; result = null;
      case 'delete': values.remove(key); result = null;
      default: throw StateError('Unexpected secure platform method');
    }
    if (fault == _Fault.after) fail();
    return result;
  }
}

class _Server {
  final calls = <String>[];
  Future<http.Response> Function(http.Request)? reply;
  Future<http.Response> handle(http.Request request) async {
    calls.add(request.url.path);
    if (reply case final handler?) return handler(request);
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
        endpoint: endpoint, clock: () => now,
        client: MockClient(server.handle),
      ),
    );
    accounts.add(account);
    return account;
  }
  Future<void> login(ServerAccountController account) => account.signIn(
    baseUrl: 'https://core.test', username: 'admin',
    password: 'synthetic-password', deviceName: 'Synthetic tablet',
  );
  setUp(() {
    platform = _Platform(); server = _Server();
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, platform.handle);
  });
  tearDown(() {
    for (final account in accounts) { account.dispose(); }
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
}
