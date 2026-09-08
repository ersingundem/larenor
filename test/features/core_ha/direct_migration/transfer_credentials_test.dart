import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// The pinned plugin's actual method-channel seam, rather than a store stub.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/features/auth/data/credentials_store.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';

import '../../../core/direct_home_boundary_test.dart' as fixture;

class TransferPlatform extends fixture.SecurePlatform {
  Future<void> Function(String key)? afterRead;
  Object? readError;
  @override
  Future<Object?> handle(MethodCall call) async {
    if (call.method == 'read' && readError != null) throw readError!;
    final result = await super.handle(call);
    if (call.method == 'read') {
      await afterRead?.call((call.arguments as Map)['key'] as String);
    }
    return result;
  }
}

Matcher failure(String code) =>
    isA<DirectHomeAccessException>().having((e) => e.code, 'safe code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TransferPlatform platform;
  late FlutterSecureStoragePlatform previous;
  setUp(() {
    platform = TransferPlatform();
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          platform.handle,
        );
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
    'explicit transfer reads the actual HA pair without mutating it',
    () async {
      final value = await CredentialsStore().readForTransfer(
        isCurrent: () => true,
      );
      expect(value?.baseUrl, 'https://synthetic.invalid');
      expect(value?.token, 'synthetic-secret');
      expect(platform.calls, [
        ('read', CredentialsStore.pendingMutationKey),
        ('read', 'ha_base_url'),
        ('read', 'ha_token'),
      ]);
      expect(platform.values['ha_token'], 'synthetic-secret');
    },
  );

  for (final throws in [false, true]) {
    test('invalid initial action (throws=$throws) reads zero keys', () async {
      await expectLater(
        CredentialsStore().readForTransfer(
          isCurrent: () {
            if (throws) throw StateError('private-sentinel');
            return false;
          },
        ),
        throwsA(failure('unavailable')),
      );
      expect(platform.calls, isEmpty);
    });
  }

  const keys = [CredentialsStore.pendingMutationKey, 'ha_base_url', 'ha_token'];
  for (var index = 0; index < keys.length; index++) {
    test(
      'action loss after platform read ${keys[index]} stops continuation',
      () async {
        var active = true;
        platform.afterRead = (key) async {
          if (key == keys[index]) active = false;
        };
        await expectLater(
          CredentialsStore().readForTransfer(isCurrent: () => active),
          throwsA(failure('unavailable')),
        );
        expect(
          platform.calls,
          keys.take(index + 1).map((key) => ('read', key)),
        );
      },
    );
  }

  test('queued action retirement precedes first platform read', () async {
    final release = Completer<void>();
    final queued = ConfigurationWrites.run(() => release.future);
    var active = true;
    final operation = CredentialsStore().readForTransfer(
      isCurrent: () => active,
    );
    final failed = expectLater(operation, throwsA(failure('unavailable')));
    active = false;
    release.complete();
    await queued;
    await failed;
    expect(platform.calls, isEmpty);
  });

  test('Core borrowed store cannot read a transfer pair', () async {
    final (container, _) = await fixture.containerFor(HomeSource.verifiedCore);
    final handle = container.listen(credentialsStoreProvider, (_, _) {});
    addTearDown(handle.close);
    await expectLater(
      handle.read().readForTransfer(isCurrent: () => true),
      throwsA(failure('unavailable')),
    );
    expect(platform.calls, isEmpty);
  });

  test('source retirement during URL read stops token read', () async {
    final (container, home) = await fixture.containerFor(
      HomeSource.directLocal,
    );
    final handle = container.listen(credentialsStoreProvider, (_, _) {});
    addTearDown(handle.close);
    platform.afterRead = (key) async {
      if (key == 'ha_base_url') await home.choose(HomeSource.verifiedCore);
    };
    await expectLater(
      handle.read().readForTransfer(isCurrent: () => true),
      throwsA(failure('unavailable')),
    );
    expect(platform.calls, keys.take(2).map((key) => ('read', key)));
  });

  for (final missing in ['ha_base_url', 'ha_token']) {
    test('half credential tuple missing $missing is rejected', () async {
      platform.values.remove(missing);
      await expectLater(
        CredentialsStore().readForTransfer(isCurrent: () => true),
        throwsA(failure('invalid_record')),
      );
      expect(platform.calls.every((call) => call.$1 == 'read'), isTrue);
    });
  }
  for (final token in ['', 'with space', '\n', '\u00e9', 'x' * 2049]) {
    test(
      'invalid transfer token case ${token.length}/${token.codeUnits.firstOrNull}',
      () async {
        platform.values['ha_token'] = token;
        await expectLater(
          CredentialsStore().readForTransfer(isCurrent: () => true),
          throwsA(failure('invalid_record')),
        );
      },
    );
  }
  test('pending marker blocks pair reads and remains untouched', () async {
    platform.values[CredentialsStore.pendingMutationKey] = '';
    await expectLater(
      CredentialsStore().readForTransfer(isCurrent: () => true),
      throwsA(failure('pending_mutation')),
    );
    expect(platform.calls, [('read', CredentialsStore.pendingMutationKey)]);
    expect(platform.values[CredentialsStore.pendingMutationKey], '');
  });
  test(
    'platform failure is static and ordinary inactive reads are unchanged',
    () async {
      platform.readError = PlatformException(code: 'private-sentinel');
      await expectLater(
        CredentialsStore().readForTransfer(isCurrent: () => true),
        throwsA(failure('storage_failed')),
      );
      platform.readError = null;
      final (container, home) = await fixture.containerFor(
        HomeSource.directLocal,
      );
      home.interaction.setActive(false);
      final handle = container.listen(credentialsStoreProvider, (_, _) {});
      addTearDown(handle.close);
      expect((await handle.read().read())?.token, 'synthetic-secret');
      expect(platform.calls, keys.map((key) => ('read', key)));
    },
  );
}
