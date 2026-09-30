import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/ssh/ssh_security_store.dart';
import 'package:larenor/features/remote_access/ssh/ssh_tunnel_models.dart';

import '../remote_profiles_test.dart' show profile;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final disk = <String, String>{};
  final calls = <MethodCall>[];
  late FlutterSecureStoragePlatform previous;
  late SshSecurityStore store;
  bool current = true;
  Future<Object?> Function(MethodCall)? intercept;
  const password = SshCredential(
    SshCredentialKind.password,
    'private-password',
  );
  const pin = SshHostPin(
    'ssh-ed25519',
    'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  );
  setUp(() async {
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    disk.clear();
    calls.clear();
    current = true;
    intercept = null;
    store = SshSecurityStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (c) async {
            calls.add(c);
            if (intercept != null) return intercept!(c);
            final a = c.arguments as Map;
            final k = a['key'] as String;
            switch (c.method) {
              case 'read':
                return disk[k];
              case 'write':
                disk[k] = a['value'];
                return null;
              case 'delete':
                disk.remove(k);
                return null;
              default:
                throw StateError('unexpected');
            }
          },
        );
    final profiles = RemoteProfilesStore();
    await profiles.replace(await profiles.read(isCurrent: () => true), [
      profile(),
    ], isCurrent: () => true);
    calls.clear();
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
    'actual secure password and key records are separate from profile JSON',
    () async {
      final before = disk[RemoteProfilesStore.storageKey];
      await store.saveCredential(profile(), password, isCurrent: () => current);
      expect(
        (await store.readCredential(
          profile(),
          isCurrent: () => current,
        ))!.secret,
        password.secret,
      );
      expect(disk[RemoteProfilesStore.storageKey], before);
      expect(before, isNot(contains(password.secret)));
      const key = SshCredential(
        SshCredentialKind.privateKey,
        '-----BEGIN OPENSSH PRIVATE KEY-----\nsynthetic\n-----END OPENSSH PRIVATE KEY-----',
        passphrase: 'secret-phrase',
      );
      await store.saveCredential(profile(), key, isCurrent: () => current);
      final saved = await store.readCredential(
        profile(),
        isCurrent: () => current,
      );
      expect(saved!.kind, key.kind);
      expect(saved.passphrase, key.passphrase);
      expect(saved.toString(), isNot(contains('secret-phrase')));
      await store.forgetCredential(profile(), isCurrent: () => current);
      expect(
        await store.readCredential(profile(), isCurrent: () => current),
        isNull,
      );
    },
  );
  test('references bind exact profile and endpoint identity', () {
    expect(
      store.reference(profile()),
      isNot(store.reference(profile(host: 'other.example'))),
    );
    expect(
      store.reference(profile()),
      isNot(store.reference(profile(port: 2222))),
    );
    expect(store.reference(profile()), isNot(contains('nas.example')));
  });
  test(
    'Core, account, endpoint, family and local sources have isolated records',
    () async {
      SshSecurityStore managed({
        String endpoint = 'https://core.example/',
        String? coreId,
        String? accountId,
        String? familyId,
      }) => SshSecurityStore(
        namespace: SshSecurityNamespace.coreManaged(
          endpoint: endpoint,
          coreId: coreId ?? '1' * 32,
          homeId: '2' * 32,
          accountId: accountId ?? '3' * 32,
          sessionFamilyId: familyId ?? '4' * 32,
        ),
        profileValidator: (_, check) async => check(),
      );

      final owner = managed();
      await owner.saveCredential(profile(), password, isCurrent: () => true);
      expect(
        (await owner.readCredential(profile(), isCurrent: () => true))!.secret,
        password.secret,
      );
      for (final stranger in [
        managed(endpoint: 'https://other.example/'),
        managed(coreId: '5' * 32),
        managed(accountId: '6' * 32),
        managed(familyId: '7' * 32),
        store,
      ]) {
        expect(
          await stranger.readCredential(profile(), isCurrent: () => true),
          isNull,
        );
      }
      final sealed = jsonDecode(
        disk.entries.singleWhere((entry) => entry.key.contains('_v2_')).value,
      ) as Map<String, dynamic>;
      expect(sealed['version'], 2);
      expect(
        sealed['namespace'],
        isA<String>().having((v) => v.length, 'length', 64),
      );
      expect(sealed['target'], owner.reference(profile()));
      expect(jsonEncode(sealed), isNot(contains('core.example')));
      expect(jsonEncode(sealed), isNot(contains('33333333')));
    },
  );
  test(
    'legacy v1 is readable and retired only by the local namespace',
    () async {
      final target = store.reference(profile());
      final legacyKey = 'ssh_credential_v1_$target';
      disk[legacyKey] = jsonEncode({
        'version': 1,
        'target': target,
        'kind': password.kind.name,
        'secret': password.secret,
        'passphrase': password.passphrase,
      });
      final managed = SshSecurityStore(
        namespace: SshSecurityNamespace.coreManaged(
          endpoint: 'https://core.example/',
          coreId: '1' * 32,
          homeId: '2' * 32,
          accountId: '3' * 32,
          sessionFamilyId: '4' * 32,
        ),
        profileValidator: (_, check) async => check(),
      );
      expect(
        await managed.readCredential(profile(), isCurrent: () => true),
        isNull,
      );
      expect(
        (await store.readCredential(profile(), isCurrent: () => true))!.secret,
        password.secret,
      );

      await store.saveCredential(profile(), password, isCurrent: () => true);
      expect(disk, isNot(contains(legacyKey)));
      expect(disk.keys.where((key) => key.contains('_v2_')), hasLength(1));
    },
  );
  test('profile cleanup deletes only the exact namespace records', () async {
    SshSecurityStore managed(String accountId) => SshSecurityStore(
      namespace: SshSecurityNamespace.coreManaged(
        endpoint: 'https://core.example/',
        coreId: '1' * 32,
        homeId: '2' * 32,
        accountId: accountId,
        sessionFamilyId: '4' * 32,
      ),
      profileValidator: (_, check) async => check(),
    );
    final first = managed('3' * 32), second = managed('5' * 32);
    await first.saveCredential(profile(), password, isCurrent: () => true);
    await second.saveCredential(
      profile(),
      const SshCredential(SshCredentialKind.password, 'second-private'),
      isCurrent: () => true,
    );
    await first.trust(profile(), pin, isCurrent: () => true);
    await second.trust(profile(), pin, isCurrent: () => true);
    final tunnel = SshTunnelProfile.parse(
      name: 'Scoped tunnel',
      localPort: '18096',
      targetHost: '127.0.0.1',
      targetPort: '8096',
    );
    await first.saveTunnel(profile(), tunnel, isCurrent: () => true);
    await second.saveTunnel(profile(), tunnel, isCurrent: () => true);

    await first.forgetProfileRecords(profile(), isCurrent: () => true);
    expect(
      await first.readCredential(profile(), isCurrent: () => true),
      isNull,
    );
    expect(await first.readPin(profile(), isCurrent: () => true), isNull);
    expect(await first.readTunnel(profile(), isCurrent: () => true), isNull);
    expect(
      (await second.readCredential(profile(), isCurrent: () => true))!.secret,
      'second-private',
    );
    expect(
      (await second.readPin(profile(), isCurrent: () => true))!.fingerprint,
      pin.fingerprint,
    );
    expect(
      (await second.readTunnel(profile(), isCurrent: () => true))!.toJson(),
      tunnel.toJson(),
    );
  });
  test('first trust persists while changed key is never replaced', () async {
    await store.trust(profile(), pin, isCurrent: () => current);
    expect(
      (await store.readPin(profile(), isCurrent: () => current))!.fingerprint,
      pin.fingerprint,
    );
    final before = Map.of(disk);
    await expectLater(
      store.trust(
        profile(),
        const SshHostPin(
          'ssh-ed25519',
          'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        ),
        isCurrent: () => current,
      ),
      throwsA(isA<SshFailure>().having((e) => e.code, 'code', 'host_changed')),
    );
    expect(disk, before);
  });
  test('retirement after actual profile read stops credential read', () async {
    intercept = (c) async {
      current = false;
      return disk[(c.arguments as Map)['key']];
    };
    await expectLater(
      store.readCredential(profile(), isCurrent: () => current),
      throwsA(isA<SshFailure>()),
    );
    expect(calls.length, 1);
    expect(
      (calls.single.arguments as Map)['key'],
      RemoteProfilesStore.storageKey,
    );
  });
  test('deleted or edited profile cannot load old credentials', () async {
    await store.saveCredential(profile(), password, isCurrent: () => current);
    final p = RemoteProfilesStore();
    await p.replace(await p.read(isCurrent: () => true), [
      profile(host: 'new.example'),
    ], isCurrent: () => true);
    calls.clear();
    await expectLater(
      store.readCredential(profile(), isCurrent: () => current),
      throwsA(
        isA<SshFailure>().having((e) => e.code, 'code', 'profile_changed'),
      ),
    );
    expect(calls.length, 1);
  });
  test(
    'write after-effect error is static and never automatically replayed',
    () async {
      intercept = (c) async {
        final a = c.arguments as Map;
        if (c.method == 'write') {
          disk[a['key']] = a['value'];
          throw PlatformException(code: 'private-payload');
        }
        return disk[a['key']];
      };
      await expectLater(
        store.saveCredential(profile(), password, isCurrent: () => current),
        throwsA(
          isA<SshFailure>().having((e) => e.code, 'code', 'storage_failed'),
        ),
      );
      expect(calls.where((c) => c.method == 'write').length, 1);
      intercept = null;
      expect(
        (await store.readCredential(
          profile(),
          isCurrent: () => current,
        ))!.secret,
        password.secret,
      );
    },
  );
  test('corrupt secret is not empty or automatically overwritten', () async {
    await store.saveCredential(profile(), password, isCurrent: () => current);
    final key = disk.keys.singleWhere(
      (k) => k != RemoteProfilesStore.storageKey,
    );
    disk[key] = jsonEncode({'password': 'bad'});
    await expectLater(
      store.readCredential(profile(), isCurrent: () => current),
      throwsA(isA<SshFailure>()),
    );
    expect(disk[key], jsonEncode({'password': 'bad'}));
  });
  test('invalid secret and pin bounds perform no write', () async {
    for (final bad in [
      const SshCredential(SshCredentialKind.password, ''),
      SshCredential(SshCredentialKind.password, 'x' * 4097),
      SshCredential(SshCredentialKind.privateKey, 'PEM', passphrase: 'ğ' * 600),
      const SshCredential(
        SshCredentialKind.password,
        'secret',
        passphrase: 'not-applicable',
      ),
    ]) {
      await expectLater(
        store.saveCredential(profile(), bad, isCurrent: () => current),
        throwsA(isA<SshFailure>()),
      );
    }
    await expectLater(
      store.trust(
        profile(),
        const SshHostPin('bad\n', 'raw'),
        isCurrent: () => current,
      ),
      throwsA(isA<SshFailure>()),
    );
    expect(calls.where((c) => c.method == 'write'), isEmpty);
  });
  test(
    'loopback tunnel profile is encrypted separately and read back exactly',
    () async {
      final value = SshTunnelProfile.parse(
        name: 'Media tunnel',
        localPort: '18096',
        targetHost: '127.0.0.1',
        targetPort: '8096',
      );
      final profileRecord = disk[RemoteProfilesStore.storageKey];
      await store.saveTunnel(profile(), value, isCurrent: () => current);
      final saved = await store.readTunnel(profile(), isCurrent: () => current);
      expect(saved!.toJson(), value.toJson());
      expect(saved.bindAddress, '127.0.0.1');
      expect(disk[RemoteProfilesStore.storageKey], profileRecord);
      expect(profileRecord, isNot(contains('Media tunnel')));
      expect(
        disk.keys.where((key) => key.contains('tunnel_v2_')),
        hasLength(1),
      );
    },
  );
}
