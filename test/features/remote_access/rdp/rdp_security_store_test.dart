import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';

import 'rdp_models_test.dart' show fixture, profile;

void main() {
  RdpSecurityStore managed(
    FlutterSecureStorage storage, {
    String endpoint = 'https://core.example/',
    String accountId = '33333333333333333333333333333333',
    void Function()? validated,
  }) => RdpSecurityStore(
    storage: storage,
    namespace: RdpSecurityNamespace.coreManaged(
      endpoint: endpoint,
      coreId: '1' * 32,
      homeId: '2' * 32,
      accountId: accountId,
      sessionFamilyId: '4' * 32,
    ),
    profileValidator: (_, check) async {
      check();
      validated?.call();
    },
  );

  test(
    'certificate pin persists against the exact REMOTE.COMMON profile',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      final profiles = RemoteProfilesStore(storage: storage);
      final empty = await profiles.read(isCurrent: () => true);
      await profiles.replace(empty, [profile], isCurrent: () => true);
      final store = RdpSecurityStore(storage: storage, profiles: profiles);
      final pin = RdpCertificatePin.fromJson(fixture()['certificate']);

      await store.trust(profile, pin, isCurrent: () => true);
      expect(await store.readPin(profile, isCurrent: () => true), pin);
      expect(
        () => store.trust(profile, pin, isCurrent: () => true),
        throwsA(
          isA<RdpFailure>().having(
            (value) => value.code,
            'code',
            'certificate_already_pinned',
          ),
        ),
      );
    },
  );

  test('profile removal and retired owner cannot reuse a pin', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final profiles = RemoteProfilesStore(storage: storage);
    var snapshot = await profiles.read(isCurrent: () => true);
    snapshot = await profiles.replace(snapshot, [
      profile,
    ], isCurrent: () => true);
    final store = RdpSecurityStore(storage: storage, profiles: profiles);
    final pin = RdpCertificatePin.fromJson(fixture()['certificate']);
    await store.trust(profile, pin, isCurrent: () => true);
    await profiles.replace(snapshot, const [], isCurrent: () => true);

    expect(
      () => store.readPin(profile, isCurrent: () => true),
      throwsA(
        isA<RdpFailure>().having(
          (value) => value.code,
          'code',
          'profile_changed',
        ),
      ),
    );
    expect(
      () => store.readPin(profile, isCurrent: () => false),
      throwsA(
        isA<RdpFailure>().having((value) => value.code, 'code', 'retired'),
      ),
    );
  });

  test(
    'Core source namespace isolates all records and validates pre/post',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      var validations = 0;
      final owner = managed(storage, validated: () => validations++);
      final stranger = managed(storage, accountId: '5' * 32);
      final pin = RdpCertificatePin.fromJson(fixture()['certificate']);
      const credential = RdpCredential(password: 'private-password');
      const settings = RdpProfileSettings(domain: 'LARENOR');

      await owner.trust(profile, pin, isCurrent: () => true);
      await owner.saveCredential(profile, credential, isCurrent: () => true);
      await owner.saveSettings(profile, settings, isCurrent: () => true);

      expect(await owner.readPin(profile, isCurrent: () => true), pin);
      expect(
        (await owner.readCredential(profile, isCurrent: () => true))?.password,
        credential.password,
      );
      expect(
        await owner.readSettings(profile, isCurrent: () => true),
        settings,
      );
      expect(await stranger.readPin(profile, isCurrent: () => true), isNull);
      expect(
        await stranger.readCredential(profile, isCurrent: () => true),
        isNull,
      );
      expect(
        await stranger.readSettings(profile, isCurrent: () => true),
        const RdpProfileSettings(),
      );
      await stranger.trust(profile, pin, isCurrent: () => true);
      await stranger.saveCredential(
        profile,
        const RdpCredential(password: 'other-private-password'),
        isCurrent: () => true,
      );
      await stranger.saveSettings(
        profile,
        const RdpProfileSettings(domain: 'OTHER'),
        isCurrent: () => true,
      );
      expect(validations, greaterThanOrEqualTo(12));

      await owner.forgetProfileRecords(profile, isCurrent: () => true);
      expect(await owner.readPin(profile, isCurrent: () => true), isNull);
      expect(
        await owner.readCredential(profile, isCurrent: () => true),
        isNull,
      );
      expect(await stranger.readPin(profile, isCurrent: () => true), pin);
      expect(
        (await stranger.readCredential(
          profile,
          isCurrent: () => true,
        ))?.password,
        'other-private-password',
      );
      expect(
        await stranger.readSettings(profile, isCurrent: () => true),
        const RdpProfileSettings(domain: 'OTHER'),
      );
    },
  );

  test('legacy v1 records are readable and removable only by local source', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final profiles = RemoteProfilesStore(storage: storage);
    final empty = await profiles.read(isCurrent: () => true);
    await profiles.replace(empty, [profile], isCurrent: () => true);
    final local = RdpSecurityStore(storage: storage, profiles: profiles);
    final owner = managed(storage);
    final target = local.reference(profile);
    await storage.write(
      key: 'rdp_credential_v1_$target',
      value:
          '{"version":1,"target":"$target","password":"legacy-private","gatewayPassword":""}',
    );

    expect(
      (await local.readCredential(profile, isCurrent: () => true))?.password,
      'legacy-private',
    );
    expect(await owner.readCredential(profile, isCurrent: () => true), isNull);
    await owner.forgetProfileRecords(profile, isCurrent: () => true);
    expect(
      (await local.readCredential(profile, isCurrent: () => true))?.password,
      'legacy-private',
    );
    await local.forgetProfileRecords(profile, isCurrent: () => true);
    expect(await local.readCredential(profile, isCurrent: () => true), isNull);
  });

  test(
    'Core validator retirement after validation prevents storage IO',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      var current = true;
      final store = managed(storage, validated: () => current = false);

      await expectLater(
        store.readPin(profile, isCurrent: () => current),
        throwsA(
          isA<RdpFailure>().having(
            (failure) => failure.code,
            'code',
            'retired',
          ),
        ),
      );
      expect(await storage.readAll(), isEmpty);
    },
  );

  test('Core RDP store rejects another protocol before validator IO', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    var validations = 0;
    final store = managed(storage, validated: () => validations++);
    const wrong = RemoteProfile(
      id: 'f1111111111111111111111111111111',
      name: 'Wrong protocol',
      protocol: RemoteProtocol.vnc,
      host: 'wrong.example',
      port: 5900,
    );

    await expectLater(
      store.readPin(wrong, isCurrent: () => true),
      throwsA(
        isA<RdpFailure>().having(
          (failure) => failure.code,
          'code',
          'profile_changed',
        ),
      ),
    );
    expect(validations, 0);
  });
}
