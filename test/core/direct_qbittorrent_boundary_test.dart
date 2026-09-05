import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// The pinned secure-storage plugin's real platform boundary.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/core/direct_credential_record.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/media/qbittorrent/data/qbittorrent_credentials_store.dart';
import 'package:larenor/features/media/qbittorrent/providers/qbittorrent_providers.dart';

import 'direct_home_boundary_test.dart' show SecurePlatform;
import 'direct_home_routines_test.dart' show routinesHome;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final marker = DirectCredentialService.qbittorrent.pendingMutationKey;
  const original = {
    'qbittorrent_base_url': 'https://old.invalid',
    'qbittorrent_username': 'synthetic-user',
    'qbittorrent_password': 'synthetic-old-password',
  };
  setUp(() {
    secure = SecurePlatform()
      ..values.clear()
      ..values.addAll(original);
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    messenger.setMockMethodCallHandler(channel, secure.handle);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    FlutterSecureStoragePlatform.instance = previous;
  });
  for (final mode in ['core', 'pending', 'error']) {
    test(
      '$mode actual qBittorrent provider cannot read Direct credentials',
      () async {
        final (c, _) = await routinesHome(mode);
        final sub = c.listen(qbittorrentConnectionProvider, (_, _) {});
        addTearDown(sub.close);
        await expectLater(
          c.read(qbittorrentConnectionProvider.future),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(secure.calls, isEmpty);
      },
    );
  }
  test('held Core qBittorrent store cannot read save or clear', () async {
    final (c, _) = await routinesHome('core');
    final store = c.read(qbittorrentCredentialsStoreProvider);
    for (final operation in <Future<void> Function()>[
      () async {
        await store.read();
      },
      () => store.save(
        baseUrl: 'https://new.invalid',
        username: 'new-user',
        password: 'new-password',
      ),
      store.clear,
    ]) {
      await expectLater(
        Future.sync(operation),
        throwsA(isA<DirectHomeAccessException>()),
      );
    }
    expect(secure.calls, isEmpty);
  });
  test('held store is permanently retired after Direct Core Direct', () async {
    final (c, home) = await routinesHome('direct');
    final store = c.read(qbittorrentCredentialsStoreProvider);
    expect((await store.read())!.baseUrl, original['qbittorrent_base_url']);
    await home.choose(HomeSource.verifiedCore);
    await home.choose(HomeSource.directLocal);
    home.runtimeMounted(home.runtimeIdentity);
    secure.calls.clear();
    await expectLater(store.clear(), throwsA(isA<DirectHomeAccessException>()));
    expect(secure.calls, isEmpty);
    expect(secure.values, original);
  });
  for (final value in ['1', '', 'false', 'synthetic-private-marker']) {
    test(
      'pending marker length ${value.length} blocks all tuple reads',
      () async {
        secure.values[marker] = value;
        await expectLater(
          QbittorrentCredentialsStore().read(),
          throwsA(
            isA<DirectHomeAccessException>().having(
              (e) => e.code,
              'code',
              'pending_mutation',
            ),
          ),
        );
        expect(secure.calls.map((c) => c.$2), [marker]);
      },
    );
  }
  for (final field in original.keys) {
    test(
      'uncertain $field effect is quarantined until explicit complete save',
      () async {
        var fail = true;
        messenger.setMockMethodCallHandler(channel, (call) async {
          final result = await secure.handle(call);
          if (fail &&
              call.method == 'write' &&
              (call.arguments as Map)['key'] == field) {
            throw PlatformException(
              code: 'synthetic',
              message: 'synthetic-private-password',
            );
          }
          return result;
        });
        final store = QbittorrentCredentialsStore();
        await expectLater(
          store.save(
            baseUrl: 'https://new.invalid',
            username: 'new-user',
            password: 'new-password',
          ),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(secure.values[marker], '1');
        await expectLater(
          QbittorrentCredentialsStore().read(),
          throwsA(isA<DirectHomeAccessException>()),
        );
        fail = false;
        await store.save(
          baseUrl: 'https://new.invalid',
          username: 'new-user',
          password: 'new-password',
        );
        expect(secure.values.containsKey(marker), isFalse);
        final config = await QbittorrentCredentialsStore().read();
        expect(config!.baseUrl, 'https://new.invalid');
        expect(config.username, 'new-user');
        expect(config.password, 'new-password');
      },
    );
  }
  test('pending connection is explicitly removable without a login', () async {
    secure.values[marker] = '1';
    await QbittorrentCredentialsStore().clear();
    expect(secure.values, isEmpty);
    expect(await QbittorrentCredentialsStore().read(), isNull);
  });
}
