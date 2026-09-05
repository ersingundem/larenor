import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// Uses the pinned secure-storage plugin's public platform test seam.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/auth/data/credentials_store.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';

import '../../core/direct_home_boundary_test.dart' as fixture;

const _pending = 'ha_connection_pending_v1';
const _replacement = HaConnectionConfig(
  baseUrl: 'https://replacement.invalid',
  token: 'replacement-secret',
);

class _Platform extends fixture.SecurePlatform {
  Future<void> Function(String method, String? key)? before;
  Future<void> Function(String method, String? key)? after;

  @override
  Future<Object?> handle(MethodCall call) async {
    final key = (call.arguments as Map)['key'] as String?;
    await before?.call(call.method, key);
    final result = await super.handle(call);
    await after?.call(call.method, key);
    return result;
  }
}

Matcher staticFailure([String? code]) => isA<DirectHomeAccessException>()
    .having((e) => e.toString(), 'static message', isNot(contains('sentinel')))
    .having((e) => e.code, 'code', code ?? isA<String>());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Platform platform;
  late FlutterSecureStoragePlatform previous;
  setUp(() {
    platform = _Platform();
    previous = FlutterSecureStoragePlatform.instance;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          platform.handle,
        );
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  test(
    'pending state rejects before either credential key is consumed',
    () async {
      platform.values[_pending] = '1';
      await expectLater(
        CredentialsStore().read(),
        throwsA(staticFailure('pending_mutation')),
      );
      expect(platform.calls, [('read', _pending)]);
      expect(platform.values['ha_token'], 'synthetic-secret');
    },
  );

  for (final clear in [false, true]) {
    test(
      'partial ${clear ? 'clear' : 'save'} survives a new store instance',
      () async {
        platform.before = (method, key) async {
          if (key == 'ha_token' && method == (clear ? 'delete' : 'write')) {
            throw const FormatException('sentinel-private-platform-error');
          }
        };
        final store = CredentialsStore();
        await expectLater(
          clear ? store.clear() : store.save(_replacement),
          throwsA(staticFailure('write_unconfirmed')),
        );
        expect(platform.values[_pending], isNotNull);
        expect(
          platform.values['ha_base_url'],
          clear ? null : _replacement.baseUrl,
        );
        expect(platform.values['ha_token'], 'synthetic-secret');
        platform.before = null;
        platform.calls.clear();
        await expectLater(
          CredentialsStore().read(),
          throwsA(staticFailure('pending_mutation')),
        );
        expect(platform.calls, [('read', _pending)]);
        expect(platform.values[_pending], isNotNull);
      },
    );

    test(
      'explicit complete ${clear ? 'clear' : 'save'} recovers pending state',
      () async {
        platform.values[_pending] = '1';
        final store = CredentialsStore();
        if (clear) {
          await store.clear();
        } else {
          await store.save(_replacement);
        }
        expect(platform.values.containsKey(_pending), isFalse);
        final restored = await CredentialsStore().read();
        expect(restored?.baseUrl, clear ? null : _replacement.baseUrl);
        expect(restored?.token, clear ? null : _replacement.token);
        expect(platform.calls.take(4), [
          ('write', _pending),
          (clear ? 'delete' : 'write', 'ha_base_url'),
          (clear ? 'delete' : 'write', 'ha_token'),
          ('delete', _pending),
        ]);
      },
    );
  }

  for (final afterEffect in [false, true]) {
    test(
      'marker write failure ${afterEffect ? 'after' : 'before'} effect never touches pair',
      () async {
        Future<void> fail(String method, String? key) async {
          if (method == 'write' && key == _pending)
            throw StateError('sentinel');
        }

        if (afterEffect) {
          platform.after = fail;
        } else {
          platform.before = fail;
        }
        await expectLater(
          CredentialsStore().save(_replacement),
          throwsA(staticFailure('write_unconfirmed')),
        );
        expect(platform.values['ha_base_url'], 'https://synthetic.invalid');
        expect(platform.values['ha_token'], 'synthetic-secret');
        expect(platform.calls.where((c) => c.$2 != _pending), isEmpty);
        platform.before = null;
        platform.after = null;
        if (afterEffect) {
          await expectLater(
            CredentialsStore().read(),
            throwsA(staticFailure('pending_mutation')),
          );
        } else {
          expect((await CredentialsStore().read())?.token, 'synthetic-secret');
        }
      },
    );

    test(
      'marker removal failure ${afterEffect ? 'after' : 'before'} effect never rolls back',
      () async {
        Future<void> fail(String method, String? key) async {
          if (method == 'delete' && key == _pending)
            throw StateError('sentinel');
        }

        if (afterEffect) {
          platform.after = fail;
        } else {
          platform.before = fail;
        }
        await expectLater(
          CredentialsStore().save(_replacement),
          throwsA(staticFailure('write_unconfirmed')),
        );
        expect(platform.values['ha_base_url'], _replacement.baseUrl);
        expect(platform.values['ha_token'], _replacement.token);
        expect(platform.calls.where((c) => c.$1 == 'write').length, 3);
        platform.before = null;
        platform.after = null;
        if (afterEffect) {
          expect((await CredentialsStore().read())?.token, _replacement.token);
        } else {
          await expectLater(
            CredentialsStore().read(),
            throwsA(staticFailure('pending_mutation')),
          );
        }
      },
    );
  }

  test('source switch after URL effect retires writer and preserves pending marker', () async {
    final (container, home) = await fixture.containerFor(
      HomeSource.directLocal,
    );
    final sub = container.listen(credentialsStoreProvider, (_, _) {});
    addTearDown(sub.close);
    final store = sub.read();
    platform.after = (method, key) async {
      if (method == 'write' && key == 'ha_base_url')
        await home.choose(HomeSource.verifiedCore);
    };
    await expectLater(
      store.save(_replacement),
      throwsA(staticFailure('write_unconfirmed')),
    );
    expect(platform.values[_pending], isNotNull);
    expect(platform.values['ha_token'], 'synthetic-secret');
    expect(platform.calls, [('write', _pending), ('write', 'ha_base_url')]);
    platform.after = null;
    await home.choose(HomeSource.directLocal);
    await expectLater(store.clear(), throwsA(staticFailure('unavailable')));
    await expectLater(
      CredentialsStore().read(),
      throwsA(staticFailure('pending_mutation')),
    );
  });

  test('queued stale writer never writes marker or pair', () async {
    final (container, home) = await fixture.containerFor(
      HomeSource.directLocal,
    );
    final sub = container.listen(credentialsStoreProvider, (_, _) {});
    addTearDown(sub.close);
    final release = Completer<void>();
    final blocker = ConfigurationWrites.run(() => release.future);
    final write = sub.read().save(_replacement);
    final failed = expectLater(write, throwsA(staticFailure('unavailable')));
    await home.choose(HomeSource.verifiedCore);
    release.complete();
    await blocker;
    await failed;
    expect(platform.calls, isEmpty);
  });

  test(
    'read waits behind a mutation and never observes its partial pair',
    () async {
      final reached = Completer<void>();
      final release = Completer<void>();
      platform.after = (method, key) async {
        if (method == 'write' && key == 'ha_base_url') {
          reached.complete();
          await release.future;
        }
      };
      final save = CredentialsStore().save(_replacement);
      await reached.future;
      final read = CredentialsStore().read();
      await Future<void>.delayed(Duration.zero);
      expect(platform.calls.where((c) => c.$1 == 'read'), isEmpty);
      release.complete();
      await save;
      expect((await read)?.token, _replacement.token);
    },
  );
}
