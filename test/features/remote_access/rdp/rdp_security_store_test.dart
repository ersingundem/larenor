import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';

import 'rdp_models_test.dart' show fixture, profile;

void main() {
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
}
