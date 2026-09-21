import 'dart:async';
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
        expectedAccountId: profileAccountId,
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
          expectedAccountId: profileAccountId,
        ),
        throwsA(isA<LarenorServerException>()),
      );
      final secret = profileJson()..['pin'] = 'private-pin';
      expect(
        () => CorePersonalProfilesSnapshot.fromJson(
          listJson(secret),
          expectedContext: context,
          expectedAccountId: profileAccountId,
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
        'requestId',
        'expectedAccountRevision',
        'expectedCollectionRevision',
        'expectedRevision',
      });
      expect(
        patch.url.path,
        '/prefix/api/v1/core-remote-profiles/'
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/'
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/$profileId',
      );

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

  test(
    'session-family and account-revision drift cannot replace verified rows',
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
      final retained = controller.profiles.single;

      fixture.familyId = 'f' * 32;
      fixture.record = profileJson(revision: 2, label: 'Foreign family');
      fixture.collectionRevisionOverride = 2;
      await controller.refresh();
      expect(controller.profiles.single.profile.name, retained.profile.name);
      expect(controller.evidence.isFreshVerified, isFalse);
      expect(controller.failure, 'invalid_response');

      fixture.familyId = profileFamilyId;
      fixture.accountRevision = 2;
      await controller.refresh();
      expect(controller.profiles.single.profile.name, retained.profile.name);
      expect(controller.evidence.isFreshVerified, isFalse);
      expect(controller.failure, 'invalid_response');
      controller.dispose();
      fixture.account.dispose();
    },
  );

  test(
    'lost mutation response reconciles by readback after controller restart',
    () async {
      final fixture = CoreProfilesFixture();
      await fixture.account.initialize();
      final first = CorePersonalProfilesController(
        account: fixture.account,
        windowCurrent: () => true,
        clock: () => fixture.now,
      );
      first.setVisible(true);
      await _settle(first);
      final target = first.profiles.single;
      fixture.losePatchResponse = true;
      await first.update(
        target,
        RemoteProfile(
          id: target.id,
          name: 'Recovered after restart',
          protocol: target.profile.protocol,
          host: target.profile.host,
          port: target.profile.port,
          username: target.profile.username,
        ),
        ownerCurrent: () => true,
      );
      expect(first.mutationOutcome, CoreProfileMutationOutcome.uncertain);
      expect(first.evidence.isFreshVerified, isFalse);
      expect(fixture.patchCalls, 1);
      first.dispose();

      final restarted = CorePersonalProfilesController(
        account: fixture.account,
        windowCurrent: () => true,
        clock: () => fixture.now,
      );
      restarted.setVisible(true);
      await _settle(restarted);
      expect(restarted.profiles.single.profile.name, 'Recovered after restart');
      expect(restarted.profiles.single.revision, 2);
      expect(restarted.evidence.isFreshVerified, isTrue);
      await restarted.refresh();
      expect(fixture.patchCalls, 1);
      expect(restarted.profiles.single.revision, 2);
      restarted.dispose();
      fixture.account.dispose();
    },
  );

  test('mutation rejects a stale collection revision readback', () async {
    final fixture = CoreProfilesFixture();
    await fixture.account.initialize();
    final controller = CorePersonalProfilesController(
      account: fixture.account,
      windowCurrent: () => true,
      clock: () => fixture.now,
    );
    controller.setVisible(true);
    await _settle(controller);
    final target = controller.profiles.single;
    fixture.collectionRevisionOverride = 1;

    await controller.update(
      target,
      RemoteProfile(
        id: target.id,
        name: 'Server changed without collection revision',
        protocol: target.profile.protocol,
        host: target.profile.host,
        port: target.profile.port,
        username: target.profile.username,
      ),
      ownerCurrent: () => true,
    );

    expect(controller.mutationOutcome, CoreProfileMutationOutcome.uncertain);
    expect(controller.evidence.isFreshVerified, isFalse);
    expect(controller.profiles.single.profile.name, 'Living room desktop');
    controller.dispose();
    fixture.account.dispose();
  });

  test('refresh rejects collection revision rollback in one session', () async {
    final fixture = CoreProfilesFixture()
      ..record = profileJson(revision: 2, label: 'Current Core value');
    await fixture.account.initialize();
    final controller = CorePersonalProfilesController(
      account: fixture.account,
      windowCurrent: () => true,
      clock: () => fixture.now,
    );
    controller.setVisible(true);
    await _settle(controller);
    expect(controller.snapshot?.collectionRevision, 2);

    fixture.record = profileJson(revision: 1, label: 'Rolled back value');
    fixture.collectionRevisionOverride = 1;
    await controller.refresh();

    expect(controller.profiles.single.profile.name, 'Current Core value');
    expect(controller.snapshot?.collectionRevision, 2);
    expect(controller.evidence.isFreshVerified, isFalse);
    controller.dispose();
    fixture.account.dispose();
  });

  test(
    'late list is discarded after route and session family retire',
    () async {
      final fixture = CoreProfilesFixture();
      await fixture.account.initialize();
      final controller = CorePersonalProfilesController(
        account: fixture.account,
        windowCurrent: () => true,
        clock: () => fixture.now,
      );
      final held = Completer<void>();
      fixture.holdNextList = held;
      controller.setVisible(true);
      await Future<void>.delayed(Duration.zero);
      expect(controller.busy, isTrue);

      controller.setVisible(false);
      final logout = fixture.account.signOut();
      held.complete();
      await logout;
      await Future<void>.delayed(Duration.zero);

      expect(controller.profiles, isEmpty);
      expect(controller.loaded, isFalse);
      expect(controller.evidence.stage, ConnectionEvidenceStage.none);
      expect(controller.mutationOutcome, isNull);
      controller.dispose();
      fixture.account.dispose();
    },
  );
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
