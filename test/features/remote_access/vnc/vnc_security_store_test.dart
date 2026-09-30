import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/vnc/vnc_models.dart';
import 'package:larenor/features/remote_access/vnc/vnc_security_store.dart';

import 'vnc_models_test.dart' show fixture, profile;

void main() {
  VncSecurityStore managed(
    FlutterSecureStorage storage, {
    String endpoint = 'https://core.example/',
    String accountId = '33333333333333333333333333333333',
    void Function()? validated,
  }) => VncSecurityStore(
    storage: storage,
    namespace: VncSecurityNamespace.coreManaged(
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
      final store = VncSecurityStore(storage: storage, profiles: profiles);
      final pin = VncCertificatePin.fromJson(fixture()['certificate']);

      await store.trust(profile, pin, isCurrent: () => true);
      expect(await store.readPin(profile, isCurrent: () => true), pin);
      expect(
        () => store.trust(profile, pin, isCurrent: () => true),
        throwsA(
          isA<VncFailure>().having(
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
    final store = VncSecurityStore(storage: storage, profiles: profiles);
    final pin = VncCertificatePin.fromJson(fixture()['certificate']);
    await store.trust(profile, pin, isCurrent: () => true);
    await profiles.replace(snapshot, const [], isCurrent: () => true);

    expect(
      () => store.readPin(profile, isCurrent: () => true),
      throwsA(
        isA<VncFailure>().having(
          (value) => value.code,
          'code',
          'profile_changed',
        ),
      ),
    );
    expect(
      () => store.readPin(profile, isCurrent: () => false),
      throwsA(
        isA<VncFailure>().having((value) => value.code, 'code', 'retired'),
      ),
    );
  });

  test('Core source namespace isolates pin and validates pre/post', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    var validations = 0;
    final owner = managed(storage, validated: () => validations++);
    final stranger = managed(storage, accountId: '5' * 32);
    final pin = VncCertificatePin.fromJson(fixture()['certificate']);

    await owner.trust(profile, pin, isCurrent: () => true);
    expect(await owner.readPin(profile, isCurrent: () => true), pin);
    expect(await stranger.readPin(profile, isCurrent: () => true), isNull);
    await stranger.trust(profile, pin, isCurrent: () => true);
    expect(validations, greaterThanOrEqualTo(4));

    await owner.forgetProfileRecords(profile, isCurrent: () => true);
    expect(await owner.readPin(profile, isCurrent: () => true), isNull);
    expect(await stranger.readPin(profile, isCurrent: () => true), pin);
  });

  test('legacy v1 pin is readable and removable only by local source', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final profiles = RemoteProfilesStore(storage: storage);
    final empty = await profiles.read(isCurrent: () => true);
    await profiles.replace(empty, [profile], isCurrent: () => true);
    final local = VncSecurityStore(storage: storage, profiles: profiles);
    final owner = managed(storage);
    final target = local.reference(profile);
    final pin = VncCertificatePin.fromJson(fixture()['certificate']);
    await storage.write(
      key: 'vnc_certificate_v1_$target',
      value:
          '{"version":1,"target":"$target","algorithm":"${pin.algorithm}","fingerprint":"${pin.fingerprint}"}',
    );

    expect(await local.readPin(profile, isCurrent: () => true), pin);
    expect(await owner.readPin(profile, isCurrent: () => true), isNull);
    await owner.forgetProfileRecords(profile, isCurrent: () => true);
    expect(await local.readPin(profile, isCurrent: () => true), pin);
    await local.forgetProfileRecords(profile, isCurrent: () => true);
    expect(await local.readPin(profile, isCurrent: () => true), isNull);
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
          isA<VncFailure>().having(
            (failure) => failure.code,
            'code',
            'retired',
          ),
        ),
      );
      expect(await storage.readAll(), isEmpty);
    },
  );

  test('Core VNC store rejects another protocol before validator IO', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    var validations = 0;
    final store = managed(storage, validated: () => validations++);
    const wrong = RemoteProfile(
      id: 'f2222222222222222222222222222222',
      name: 'Wrong protocol',
      protocol: RemoteProtocol.rdp,
      host: 'wrong.example',
      port: 3389,
      username: 'user',
    );

    await expectLater(
      store.readPin(wrong, isCurrent: () => true),
      throwsA(
        isA<VncFailure>().having(
          (failure) => failure.code,
          'code',
          'profile_changed',
        ),
      ),
    );
    expect(validations, 0);
  });
}
