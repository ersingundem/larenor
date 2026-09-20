import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/health/data/connection_evidence.dart';
import 'package:larenor/features/remote_access/core/core_personal_profiles.dart';
import 'package:larenor/features/remote_access/core/core_personal_profiles_controller.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'core_personal_profiles_test_support.dart';

void main() {
  final context = ServerContextFixture.value;

  test(
    'closed model binds exact account home and rejects secret-shaped drift',
    () {
      final value = CorePersonalProfilesSnapshot.fromJson(
        listJson(profileJson()),
        expectedContext: context,
      );
      expect(value.profiles.single.profile.name, 'Living room desktop');
      expect(value.toString(), isNot(contains('private-user')));
      expect(
        value.profiles.single.toString(),
        isNot(contains('desk.internal')),
      );

      final foreign = listJson(profileJson(home: 'c' * 32));
      expect(
        () => CorePersonalProfilesSnapshot.fromJson(
          foreign,
          expectedContext: context,
        ),
        throwsA(isA<LarenorServerException>()),
      );
      final secret = profileJson()..['pin'] = 'private-pin';
      expect(
        () => CorePersonalProfilesSnapshot.fromJson(
          listJson(secret),
          expectedContext: context,
        ),
        throwsA(isA<LarenorServerException>()),
      );
    },
  );

  test(
    'conflict preserves old data read-only until explicit verified refresh',
    () async {
      final fixture = CoreProfilesFixture();
      await fixture.account.initialize();
      final controller = CorePersonalProfilesController(
        account: fixture.account,
        windowCurrent: () => true,
        clock: () => fixture.now,
      );
      controller.setVisible(true);
      await _settle(controller);
      expect(controller.evidence.isFreshVerified, isTrue);
      final old = controller.profiles.single;
      fixture.record = profileJson(revision: 2, label: 'Other tablet');
      fixture.conflict = true;
      await controller.update(
        old,
        RemoteProfile(
          id: old.id,
          name: 'My stale edit',
          protocol: old.profile.protocol,
          host: old.profile.host,
          port: old.profile.port,
          username: old.profile.username,
        ),
        ownerCurrent: () => true,
      );
      expect(controller.mutationOutcome, CoreProfileMutationOutcome.conflict);
      expect(controller.profiles.single.profile.name, 'Living room desktop');
      expect(controller.evidence.condition, ConnectionEvidenceCondition.stale);
      expect(controller.canMutate, isFalse);
      final patch = fixture.calls.lastWhere((call) => call.method == 'PATCH');
      expect((jsonDecode(patch.body) as Map<String, dynamic>).keys.toSet(), {
        'label',
        'protocol',
        'host',
        'port',
        'username',
        'expectedRevision',
      });

      fixture.conflict = false;
      await controller.refresh();
      expect(controller.profiles.single.profile.name, 'Other tablet');
      expect(controller.evidence.isFreshVerified, isTrue);
      controller.dispose();
      fixture.account.dispose();
    },
  );

  test('offline read retains only visibly unverified memory cache', () async {
    final fixture = CoreProfilesFixture();
    await fixture.account.initialize();
    final controller = CorePersonalProfilesController(
      account: fixture.account,
      windowCurrent: () => true,
      clock: () => fixture.now,
    );
    controller.setVisible(true);
    await _settle(controller);
    fixture.offline = true;
    await controller.refresh();
    expect(controller.profiles, hasLength(1));
    expect(controller.evidence.condition, ConnectionEvidenceCondition.offline);
    expect(controller.evidence.isFreshVerified, isFalse);
    expect(controller.canMutate, isFalse);
    expect(controller.toString(), isNot(contains('private-user')));
    await fixture.account.signOut();
    expect(controller.profiles, isEmpty);
    expect(controller.evidence.stage, ConnectionEvidenceStage.none);
    controller.dispose();
    fixture.account.dispose();
  });
}

Future<void> _settle(CorePersonalProfilesController controller) async {
  for (var i = 0; i < 20 && controller.busy; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(controller.busy, isFalse);
}

abstract final class ServerContextFixture {
  static final value = ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'homeId': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  });
}
