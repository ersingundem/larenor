import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_schema6_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_schema6_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'core_personal_profiles_test_support.dart';
import 'remote_profiles_ui_fixture.dart';

final class _GatewayEnrollmentEngine implements RdpGatewayEnrollmentEngine {
  static const gatewayPin =
      'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  static const targetPin = 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
  int gatewayInspections = 0, targetInspections = 0;
  Uint8List? observedPassword;
  Completer<void>? targetGate;

  @override
  Future<RdpGatewayCertificateObservation> inspectGateway({
    required RdpGatewayEndpoint target,
    required RdpGatewayEndpoint gateway,
    required bool Function() isCurrent,
  }) async {
    expect(isCurrent(), isTrue);
    gatewayInspections += 1;
    return const RdpGatewayCertificateObservation(
      requestId: 'gateway-observation',
      kind: RdpGatewayCertificateKind.gateway,
      certificate: RdpCertificatePin(
        algorithm: 'spki-sha256',
        fingerprint: gatewayPin,
      ),
    );
  }

  @override
  Future<RdpGatewayCertificateObservation> inspectTargetThroughGateway({
    required RdpGatewayEndpoint target,
    required RdpPinnedGatewayEndpoint gateway,
    required RdpOwnedSecretBuffer gatewayPassword,
    required bool Function() isCurrent,
  }) async {
    expect(isCurrent(), isTrue);
    expect(gateway.fingerprint, gatewayPin);
    targetInspections += 1;
    observedPassword = gatewayPassword.bytes;
    await targetGate?.future;
    return const RdpGatewayCertificateObservation(
      requestId: 'target-observation',
      kind: RdpGatewayCertificateKind.target,
      certificate: RdpCertificatePin(
        algorithm: 'spki-sha256',
        fingerprint: targetPin,
      ),
    );
  }

  @override
  void close() {}
}

void main() {
  testWidgets(
    'unadmitted Gateway exposes no enrollment or secret persistence',
    (tester) async {
      final fixture = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = (profileJson(protocol: 'rdp')..['rdp'] = null);
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final engine = _GatewayEnrollmentEngine();
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
        gatewayEnrollmentEngine: () => engine,
        gatewayEnrollmentAdmitted: false,
      );
      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-$profileId');
      expect(key('core-rdp-gateway-host'), findsNothing);
      expect(key('core-rdp-gateway-password'), findsNothing);
      expect(key('core-rdp-inspect-gateway'), findsNothing);
      expect(key('core-rdp-accept-target-save'), findsNothing);
      expect(engine.gatewayInspections, 0);
      expect(engine.targetInspections, 0);
      expect(
        ui.values.keys.where((key) => key.startsWith('rdp_schema6_')),
        isEmpty,
      );
      expect(fixture.record['rdp'], isNull);
      expect(key('core-profile-save'), findsOneWidget);
    },
  );

  testWidgets(
    'two-stage Gateway enrollment stores separate device secret and public pins',
    (tester) async {
      final fixture = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = (profileJson(protocol: 'rdp')..['rdp'] = null);
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final engine = _GatewayEnrollmentEngine();
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
        gatewayEnrollmentEngine: () => engine,
      );

      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-$profileId');
      await tester.enterText(key('core-rdp-target-domain'), 'TARGET');
      await tester.enterText(
        key('core-rdp-gateway-host'),
        'gateway.internal.example',
      );
      await tester.enterText(key('core-rdp-gateway-port'), '443');
      await tester.enterText(key('core-rdp-gateway-user'), 'gateway-user');
      await tester.enterText(key('core-rdp-gateway-domain'), 'EDGE');
      await tester.enterText(
        key('core-rdp-gateway-password'),
        'private-gateway-password',
      );

      await press(tester, 'core-rdp-inspect-gateway');
      expect(engine.gatewayInspections, 1);
      expect(find.text(_GatewayEnrollmentEngine.gatewayPin), findsOneWidget);
      await press(tester, 'core-rdp-accept-gateway');
      expect(engine.targetInspections, 1);
      expect(find.text(_GatewayEnrollmentEngine.targetPin), findsOneWidget);
      expect(
        tester
            .widget<CupertinoTextField>(key('core-rdp-gateway-password'))
            .controller!
            .text,
        isEmpty,
      );
      expect(engine.observedPassword, isNotNull);
      expect(engine.observedPassword, everyElement(0));

      await press(tester, 'core-rdp-accept-target-save');
      expect(key('core-profile-name'), findsNothing);
      expect(fixture.record['rdp'], {
        'domain': 'TARGET',
        'certificateFingerprint': _GatewayEnrollmentEngine.targetPin,
        'gateway': {
          'host': 'gateway.internal.example',
          'port': 443,
          'username': 'gateway-user',
          'domain': 'EDGE',
          'certificateFingerprint': _GatewayEnrollmentEngine.gatewayPin,
        },
      });
      final publicRecord = jsonEncode(fixture.record);
      expect(publicRecord, isNot(contains('private-gateway-password')));
      expect(publicRecord, isNot(contains('secretRef')));
      expect(
        ui.values.keys.where(
          (value) => value.startsWith('rdp_schema6_current_secret_v1_'),
        ),
        hasLength(1),
      );
      expect(
        ui.values.values.any(
          (value) => value.contains('private-gateway-password'),
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late target inspection after Core retirement cannot mutate or retain secret',
    (tester) async {
      final fixture = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = (profileJson(protocol: 'rdp')..['rdp'] = null);
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final engine = _GatewayEnrollmentEngine()..targetGate = Completer<void>();
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
        gatewayEnrollmentEngine: () => engine,
      );
      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-$profileId');
      await tester.enterText(
        key('core-rdp-gateway-host'),
        'gateway.internal.example',
      );
      await tester.enterText(key('core-rdp-gateway-user'), 'gateway-user');
      await tester.enterText(
        key('core-rdp-gateway-password'),
        'retired-private-password',
      );
      await press(tester, 'core-rdp-inspect-gateway');
      await press(tester, 'core-rdp-accept-gateway');
      expect(engine.targetInspections, 1);
      expect(engine.observedPassword, isNotNull);

      await fixture.account.signOut();
      await tester.pump();
      engine.targetGate!.complete();
      await tester.pumpAndSettle();

      expect(fixture.patchCalls, 0);
      expect(fixture.record['rdp'], isNull);
      expect(engine.observedPassword, everyElement(0));
      expect(
        ui.values.keys.where((value) => value.startsWith('rdp_schema6_')),
        isEmpty,
      );
      expect(find.text(_GatewayEnrollmentEngine.targetPin), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'completed target observation is wiped when its Core authority retires',
    (tester) async {
      final fixture = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = (profileJson(protocol: 'rdp')..['rdp'] = null);
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final engine = _GatewayEnrollmentEngine();
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
        gatewayEnrollmentEngine: () => engine,
      );
      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-$profileId');
      await tester.enterText(
        key('core-rdp-gateway-host'),
        'gateway.internal.example',
      );
      await tester.enterText(key('core-rdp-gateway-user'), 'gateway-user');
      await tester.enterText(
        key('core-rdp-gateway-password'),
        'private-gateway-password',
      );
      await press(tester, 'core-rdp-inspect-gateway');
      await press(tester, 'core-rdp-accept-gateway');
      expect(find.text(_GatewayEnrollmentEngine.targetPin), findsOneWidget);
      expect(key('core-rdp-accept-target-save'), findsOneWidget);

      await fixture.account.signOut();
      await tester.pumpAndSettle();

      expect(find.text(_GatewayEnrollmentEngine.targetPin), findsNothing);
      expect(key('core-rdp-accept-target-save'), findsNothing);
      expect(fixture.patchCalls, 0);
      expect(fixture.record['rdp'], isNull);
      expect(
        ui.values.keys.where((value) => value.startsWith('rdp_schema6_')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new Gateway publication retires old scope and cleanup failure retries without Core replay',
    (tester) async {
      final fixture = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = (profileJson(protocol: 'rdp')..['rdp'] = null);
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final engine = _GatewayEnrollmentEngine();
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
        gatewayEnrollmentEngine: () => engine,
      );
      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-$profileId');
      await tester.enterText(
        key('core-rdp-gateway-host'),
        'gateway.internal.example',
      );
      await tester.enterText(key('core-rdp-gateway-user'), 'gateway-user');
      await tester.enterText(
        key('core-rdp-gateway-password'),
        'first-private-password',
      );
      await press(tester, 'core-rdp-inspect-gateway');
      await press(tester, 'core-rdp-accept-gateway');
      await press(tester, 'core-rdp-accept-target-save');
      expect(fixture.patchCalls, 1);
      expect(
        ui.values.keys.where(
          (value) => value.startsWith('rdp_schema6_secret_v1_'),
        ),
        hasLength(1),
      );

      await press(tester, 'core-profile-$profileId');
      await tester.enterText(key('core-rdp-gateway-domain'), 'EDGE-ROTATED');
      await tester.enterText(
        key('core-rdp-gateway-password'),
        'second-private-password',
      );
      await press(tester, 'core-rdp-inspect-gateway');
      await press(tester, 'core-rdp-accept-gateway');
      ui.failSchema6SecretDeleteOnce = true;
      await press(tester, 'core-rdp-accept-target-save');

      expect(fixture.patchCalls, 2);
      await tester.scrollUntilVisible(
        key('core-rdp-secret-cleanup-retry'),
        240,
        scrollable: find
            .descendant(
              of: key('core-profiles-scroll'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(key('core-rdp-secret-cleanup-failed'), findsOneWidget);
      expect(
        ui.values.keys.where(
          (value) => value.startsWith('rdp_schema6_current_secret_v1_'),
        ),
        hasLength(1),
      );
      expect(
        ui.values.keys.where(
          (value) => value.startsWith('rdp_schema6_secret_v1_'),
        ),
        hasLength(2),
      );

      await press(tester, 'core-rdp-secret-cleanup-retry');

      expect(fixture.patchCalls, 2);
      expect(key('core-rdp-secret-cleanup-failed'), findsNothing);
      expect(key('core-profile-name'), findsNothing);
      expect(
        ui.values.keys.where(
          (value) => value.startsWith('rdp_schema6_secret_v1_'),
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('deleting a Core RDP profile retires its schema6 secret', (
    tester,
  ) async {
    final fixture = CoreProfilesFixture()
      ..familyId = 'd' * 32
      ..record = (profileJson(protocol: 'rdp')..['rdp'] = null);
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final engine = _GatewayEnrollmentEngine();
    final ui = RemoteUi();
    await ui.mount(
      tester,
      width: 600,
      scale: 2,
      serverAccount: fixture.account,
      gatewayEnrollmentEngine: () => engine,
    );
    await press(tester, 'remote-source-core-managed');
    await press(tester, 'core-profile-$profileId');
    await tester.enterText(
      key('core-rdp-gateway-host'),
      'gateway.internal.example',
    );
    await tester.enterText(key('core-rdp-gateway-user'), 'gateway-user');
    await tester.enterText(
      key('core-rdp-gateway-password'),
      'private-gateway-password',
    );
    await press(tester, 'core-rdp-inspect-gateway');
    await press(tester, 'core-rdp-accept-gateway');
    await press(tester, 'core-rdp-accept-target-save');
    expect(
      ui.values.keys.where(
        (value) => value.startsWith('rdp_schema6_current_secret_v1_'),
      ),
      hasLength(1),
    );
    expect(
      ui.values.keys.where(
        (value) => value.startsWith('rdp_schema6_secret_v1_'),
      ),
      hasLength(1),
    );

    await press(tester, 'core-profile-$profileId');
    await press(tester, 'core-profile-delete');
    await press(tester, 'core-profile-delete-confirm');

    expect(fixture.deleteCalls, 1);
    expect(key('core-profile-$profileId'), findsNothing);
    expect(
      ui.values.keys.where((value) => value.startsWith('rdp_schema6_')),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'deleted Core profile resumes exact secret retirement after route restart',
    (tester) async {
      final fixture = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = (profileJson(protocol: 'rdp')..['rdp'] = null);
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final engine = _GatewayEnrollmentEngine();
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
        gatewayEnrollmentEngine: () => engine,
      );
      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-$profileId');
      await tester.enterText(
        key('core-rdp-gateway-host'),
        'gateway.internal.example',
      );
      await tester.enterText(key('core-rdp-gateway-user'), 'gateway-user');
      await tester.enterText(
        key('core-rdp-gateway-password'),
        'private-gateway-password',
      );
      await press(tester, 'core-rdp-inspect-gateway');
      await press(tester, 'core-rdp-accept-gateway');
      await press(tester, 'core-rdp-accept-target-save');
      await press(tester, 'core-profile-$profileId');
      await press(tester, 'core-profile-delete');
      ui.failSchema6SecretDeleteOnce = true;
      await press(tester, 'core-profile-delete-confirm');

      expect(fixture.deleteCalls, 1);
      expect(key('core-profile-local-cleanup-failed'), findsOneWidget);
      expect(ui.values.keys.where(_schema6RetirementKey), hasLength(1));
      expect(
        ui.values.keys.where(
          (value) => value.startsWith('rdp_schema6_secret_v1_'),
        ),
        hasLength(1),
      );

      await press(tester, 'core-profiles-back');
      await press(tester, 'remote-source-core-managed');
      await tester.pumpAndSettle();

      expect(fixture.deleteCalls, 1);
      expect(
        ui.values.keys.where((value) => value.startsWith('rdp_schema6_')),
        isEmpty,
      );
      expect(key('core-profile-$profileId'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'device secret publication failure never presents Core pins as ready',
    (tester) async {
      final fixture = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = (profileJson(protocol: 'rdp')..['rdp'] = null);
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final engine = _GatewayEnrollmentEngine();
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
        gatewayEnrollmentEngine: () => engine,
      );
      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-$profileId');
      await tester.enterText(
        key('core-rdp-gateway-host'),
        'gateway.internal.example',
      );
      await tester.enterText(key('core-rdp-gateway-user'), 'gateway-user');
      await tester.enterText(
        key('core-rdp-gateway-password'),
        'private-gateway-password',
      );
      await press(tester, 'core-rdp-inspect-gateway');
      await press(tester, 'core-rdp-accept-gateway');
      ui.failSchema6CurrentWrite = true;
      await press(tester, 'core-rdp-accept-target-save');

      expect(fixture.patchCalls, 1);
      expect(fixture.record['rdp'], isNotNull);
      expect(key('core-profile-name'), findsOneWidget);
      expect(key('core-rdp-gateway-enrollment-failed'), findsOneWidget);
      expect(
        ui.values.keys.where(
          (value) => value.startsWith('rdp_schema6_current_secret_v1_'),
        ),
        isEmpty,
      );
      expect(engine.observedPassword, everyElement(0));
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in ['en', 'tr']) {
    testWidgets('Core session authority failure is visible in $locale', (
      tester,
    ) async {
      final fixture = CoreProfilesFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        locale: locale,
        serverAccount: fixture.account,
      );
      await press(tester, 'remote-source-core-managed');
      expect(key('core-profile-ssh-open-$profileId'), findsOneWidget);
      fixture.offline = true;
      await press(tester, 'core-profile-ssh-open-$profileId');
      await tester.scrollUntilVisible(
        key('core-profile-session-open-failed'),
        -240,
        scrollable: find
            .descendant(
              of: key('core-profiles-scroll'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(
        tester.element(key('core-profile-session-open-failed')),
      );
      expect(find.text(l.remoteAccessCoreUnavailable), findsOneWidget);
      expect(find.textContaining('offline-marker'), findsNothing);
      expect(find.textContaining('synthetic_admin_access'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final protocol in const ['rdp', 'vnc']) {
    testWidgets('Core-managed $protocol opens its scoped desktop panel', (
      tester,
    ) async {
      final fixture = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = profileJson(
          protocol: protocol,
          username: protocol == 'vnc' ? '' : 'private-user',
        );
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
      );

      await press(tester, 'remote-source-core-managed');
      expect(key('core-profile-$protocol-open-$profileId'), findsOneWidget);
      expect(key('core-profile-ssh-open-$profileId'), findsNothing);
      await press(tester, 'core-profile-$protocol-open-$profileId');
      expect(key('core-profile-session-open-failed'), findsNothing);
      expect(key('core-$protocol-$profileId'), findsOneWidget);
      expect(find.textContaining('synthetic_admin_access'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$locale ${width.toInt()} 2x exposes local/Core sources and keyboard Core flow',
        (tester) async {
          final fixture = CoreProfilesFixture();
          await fixture.account.initialize();
          addTearDown(fixture.account.dispose);
          final ui = RemoteUi();
          await ui.mount(
            tester,
            width: width,
            scale: 2,
            locale: locale,
            serverAccount: fixture.account,
          );

          final source = key('remote-source-core-managed');
          expect(source, findsOneWidget);
          expect(tester.getRect(source).height, greaterThanOrEqualTo(48));
          final semantics = tester.getSemantics(source);
          expect(semantics.flagsCollection.isButton, isTrue);
          expect(
            semantics.label,
            contains(locale == 'en' ? 'Larenor Core' : 'Larenor Core'),
          );

          await press(tester, 'remote-source-core-managed');
          await tester.pumpAndSettle();
          expect(key('core-profile-$profileId'), findsOneWidget);
          expect(key('core-profile-ssh-open-$profileId'), findsOneWidget);
          expect(key('core-profile-sftp-open-$profileId'), findsOneWidget);
          expect(key('core-profile-tunnel-open-$profileId'), findsOneWidget);
          expect(find.textContaining('synthetic_admin_access'), findsNothing);
          expect(find.textContaining('private-user'), findsNothing);

          final row = key('core-profile-$profileId');
          await tester.ensureVisible(row);
          final rowText = find
              .descendant(of: row, matching: find.byType(Text))
              .first;
          Focus.of(tester.element(rowText)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(key('core-profile-name'), findsOneWidget);
          expect(tester.takeException(), isNull);

          final l = AppLocalizations.of(
            tester.element(key('core-profile-name')),
          );
          expect(find.text(l.remoteAccessCoreManaged), findsWidgets);
          await tester.ensureVisible(key('core-profile-user'));
          await tester.pumpAndSettle();
          await tester.tap(key('core-profile-user'));
          await tester.pump();
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(key('core-profiles-back')).height,
            greaterThanOrEqualTo(48),
          );
        },
      );
    }

    testWidgets('Core-managed RDP with empty username cannot mint a session', (
      tester,
    ) async {
      final fixture = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = profileJson(protocol: 'rdp', username: '');
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
      );

      await press(tester, 'remote-source-core-managed');
      expect(key('core-profile-rdp-open-$profileId'), findsNothing);
      expect(key('core-rdp-$profileId'), findsNothing);
    });

    testWidgets('Core logout retires an open desktop panel without replay', (
      tester,
    ) async {
      final fixture = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = profileJson(protocol: 'rdp');
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
      );

      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-rdp-open-$profileId');
      expect(key('core-rdp-$profileId'), findsOneWidget);
      final getCalls = fixture.calls
          .where((call) => call.method == 'GET')
          .length;

      await fixture.account.signOut();
      await tester.pumpAndSettle();
      expect(key('core-rdp-$profileId'), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      expect(
        fixture.calls.where((call) => call.method == 'GET').length,
        getCalls,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'conflict refresh rebinds the draft without automatic overwrite',
    (tester) async {
      final fixture = CoreProfilesFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
      );
      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-$profileId');
      await tester.enterText(key('core-profile-name'), 'My reviewed edit');
      fixture.record = profileJson(revision: 2, label: 'Other tablet edit');
      fixture.conflict = true;
      await press(tester, 'core-profile-save');
      expect(find.textContaining('changed on Core'), findsOneWidget);
      expect(fixture.record['label'], 'Other tablet edit');

      fixture.conflict = false;
      await press(tester, 'core-profiles-refresh');
      await press(tester, 'core-profile-save');
      expect(fixture.record['label'], 'My reviewed edit');
      expect(fixture.record['revision'], 3);
      expect(key('core-profile-name'), findsNothing);
    },
  );

  testWidgets(
    'Core delete exposes exact local cleanup failure and retries no server mutation',
    (tester) async {
      final fixture = CoreProfilesFixture()..familyId = 'd' * 32;
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final ui = RemoteUi()..failSshDelete = true;
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
      );
      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-$profileId');
      await press(tester, 'core-profile-delete');
      expect(
        tester
            .widget<CupertinoButton>(
              find.descendant(
                of: key('core-profile-delete-confirm'),
                matching: find.byType(CupertinoButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      await press(tester, 'core-profile-delete-confirm');
      await tester.pump(const Duration(seconds: 1));

      expect(
        fixture.deleteCalls,
        1,
        reason: fixture.calls
            .map((call) => '${call.method} ${call.url.path}')
            .join('\n'),
      );
      expect(key('core-profile-$profileId'), findsNothing);
      await tester.scrollUntilVisible(
        key('core-profile-local-cleanup-retry'),
        240,
        scrollable: find
            .descendant(
              of: key('core-profiles-scroll'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(key('core-profile-local-cleanup-failed'), findsOneWidget);
      expect(key('core-profile-local-cleanup-retry'), findsOneWidget);

      ui.failSshDelete = false;
      await press(tester, 'core-profile-local-cleanup-retry');

      expect(fixture.deleteCalls, 1);
      expect(key('core-profile-local-cleanup-failed'), findsNothing);
      expect(
        ui.calls.where((call) => call.startsWith('delete:ssh_')).length,
        4,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final protocol in const ['rdp', 'vnc']) {
    testWidgets('Core $protocol delete retries only typed local cleanup', (
      tester,
    ) async {
      final fixture = CoreProfilesFixture()
        ..familyId = 'd' * 32
        ..record = profileJson(
          protocol: protocol,
          username: protocol == 'vnc' ? '' : 'private-user',
        );
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final ui = RemoteUi()..failDesktopDelete = true;
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
      );
      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-$profileId');
      await press(tester, 'core-profile-delete');
      await press(tester, 'core-profile-delete-confirm');
      await tester.pump(const Duration(seconds: 1));
      expect(fixture.deleteCalls, 1);
      expect(key('core-profile-local-cleanup-failed'), findsOneWidget);

      ui.failDesktopDelete = false;
      await press(tester, 'core-profile-local-cleanup-retry');
      expect(fixture.deleteCalls, 1);
      expect(key('core-profile-local-cleanup-failed'), findsNothing);
      expect(
        ui.calls.where((call) => call.startsWith('delete:${protocol}_')).length,
        protocol == 'rdp' ? 4 : 2,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

bool _schema6RetirementKey(String value) =>
    value.startsWith('rdp_schema6_secret_retirements_v1_');
