import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/core/core_managed_profile_authority.dart';
import 'package:larenor/features/remote_access/core/core_personal_profiles.dart';
import 'package:larenor/features/remote_access/core/core_personal_profiles_api.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/ssh/ssh_security_store.dart';
import 'package:larenor/features/remote_access/vnc/vnc_models.dart';

import 'core_personal_profiles_test_support.dart';

Future<CorePersonalProfilesSnapshot> _snapshot(CoreProfilesFixture fixture) =>
    fixture.account.withSession(
      (api, session) => CorePersonalProfilesApi(
        api,
        session.accessToken,
        session.context!,
        session.user.id,
        current: () => true,
      ).list(),
    );

void main() {
  test('exact Core profile drift retires the live authority poll', () async {
    final fixture = CoreProfilesFixture()..familyId = 'd' * 32;
    addTearDown(fixture.account.dispose);
    await fixture.account.initialize();
    final snapshot = await _snapshot(fixture);
    final authority = CoreManagedProfileAuthority(
      account: fixture.account,
      profile: snapshot.profiles.single,
      authority: snapshot.authority,
      ownerCurrent: () => true,
      refreshInterval: const Duration(milliseconds: 5),
    );
    addTearDown(authority.dispose);

    await authority.start();
    expect(authority.isCurrent, isTrue);
    fixture.record = profileJson(revision: 2, label: 'Changed on Core');
    fixture.storedCollectionRevision = 2;

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(authority.isCurrent, isFalse);
  });

  test('session replacement retires before another profile check', () async {
    final fixture = CoreProfilesFixture()..familyId = 'd' * 32;
    addTearDown(fixture.account.dispose);
    await fixture.account.initialize();
    final snapshot = await _snapshot(fixture);
    final authority = CoreManagedProfileAuthority(
      account: fixture.account,
      profile: snapshot.profiles.single,
      authority: snapshot.authority,
      ownerCurrent: () => true,
    );
    addTearDown(authority.dispose);
    await authority.start();

    var retireNotifications = 0;
    authority.addListener(() => retireNotifications++);

    await fixture.account.signOut();
    expect(authority.isCurrent, isFalse);
    expect(retireNotifications, 1);
    authority.retire();
    expect(retireNotifications, 1);
    await expectLater(
      authority.validateProfile(snapshot.profiles.single.profile, () {}),
      throwsA(
        isA<SshFailure>().having((value) => value.code, 'code', 'retired'),
      ),
    );
  });

  for (final protocol in const ['rdp', 'vnc']) {
    test('$protocol store revalidates exact live Core authority', () async {
      final fixture = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = profileJson(
          protocol: protocol,
          username: protocol == 'vnc' ? '' : 'private-user',
        );
      addTearDown(fixture.account.dispose);
      await fixture.account.initialize();
      final snapshot = await _snapshot(fixture);
      final authority = CoreManagedProfileAuthority(
        account: fixture.account,
        profile: snapshot.profiles.single,
        authority: snapshot.authority,
        ownerCurrent: () => true,
      );
      addTearDown(authority.dispose);
      await authority.start();

      if (protocol == 'rdp') {
        await authority.createRdpSecurityStore().checkProfile(
          snapshot.profiles.single.profile,
          isCurrent: () => true,
        );
      } else {
        await authority.createVncSecurityStore().checkProfile(
          snapshot.profiles.single.profile,
          isCurrent: () => true,
        );
      }
      fixture.record = profileJson(
        revision: 2,
        protocol: protocol,
        username: protocol == 'vnc' ? '' : 'private-user',
        label: 'Drifted on Core',
      );
      fixture.storedCollectionRevision = 2;

      if (protocol == 'rdp') {
        await expectLater(
          authority.createRdpSecurityStore().checkProfile(
            snapshot.profiles.single.profile,
            isCurrent: () => true,
          ),
          throwsA(isA<RdpFailure>()),
        );
      } else {
        await expectLater(
          authority.createVncSecurityStore().checkProfile(
            snapshot.profiles.single.profile,
            isCurrent: () => true,
          ),
          throwsA(isA<VncFailure>()),
        );
      }
      expect(authority.isCurrent, isFalse);
    });
  }
}
