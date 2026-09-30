import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/kiosk/data/kiosk_api.dart';
import 'package:larenor/features/kiosk/domain/kiosk_models.dart';
import 'package:larenor/features/kiosk/presentation/kiosk_controlled_view_screen.dart';
import 'package:larenor/features/kiosk/presentation/kiosk_screen.dart';
import 'package:larenor/features/kiosk/providers/kiosk_providers.dart';
import 'package:larenor/features/kiosk_remote/data/kiosk_remote_api.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_credential_store.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_mqtt_runtime.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_mqtt_settings.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_runtime_owner.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_runtime_scope.dart';
import 'package:larenor/features/kiosk_remote/runtime/mqtt_local_broker.dart';
import 'package:larenor/features/kiosk_remote/runtime/native_managed_tablet_source.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/k09_tls_mqtt_fixture.dart';

final class _NoSessionStore implements ServerSessionPersistence {
  @override
  Future<Never?> read() async => null;

  @override
  Future<void> write(Object? session) async {}
}

final class _CredentialStore implements ManagedTabletCredentialStore {
  _CredentialStore(this.value);
  ManagedTabletEnrollment? value;

  @override
  Future<ManagedTabletEnrollment?> read() async => value;

  @override
  Future<void> write(ManagedTabletEnrollment value) async {
    this.value = value;
  }

  @override
  Future<void> clearIfCurrent(
    ManagedTabletBinding binding,
    String pairingId,
  ) async {
    if (value?.binding == binding && value?.pairingId == pairingId) {
      value = null;
    }
  }

  @override
  Future<void> clearIfExact(ManagedTabletEnrollment enrollment) async {
    if (value?.binding == enrollment.binding &&
        value?.pairingId == enrollment.pairingId &&
        value?.revision == enrollment.revision) {
      value = null;
    }
  }
}

final class _ObservedSource implements ManagedTabletSourcePort {
  bool foreground = true;
  int binds = 0, retires = 0;

  @override
  Future<NativeManagedTabletSourceLease?> bind(String scope) async {
    if (!foreground) return null;
    binds += 1;
    return const _ObservedLease();
  }

  @override
  Future<void> setForeground(bool value) async {
    foreground = value;
    if (!value) await retire();
  }

  @override
  Future<void> retire() async => retires += 1;
}

final class _ObservedLease implements NativeManagedTabletSourceLease {
  const _ObservedLease();

  @override
  ManagedTabletCommandExecutor get commandExecutor => const _NoCommands();

  @override
  Future<ManagedTabletTelemetry> readTelemetry() async =>
      const ManagedTabletTelemetry(
        batteryPercent: 64,
        charging: true,
        network: 'wifi',
        appVersion: '1.0.0',
        appBuild: 1,
        appForeground: true,
        kioskState: 'foreground',
        memoryUsedMb: 96,
        memoryLimitMb: 512,
        processUptimeSeconds: 300,
      );
}

final class _NoCommands implements ManagedTabletCommandExecutor {
  const _NoCommands();

  @override
  Future<ManagedTabletCommandResult> execute(String kind) async =>
      ManagedTabletCommandResult.unsupported;
}

final class _ReadOnlyKioskApi extends KioskApi {
  int policyWrites = 0;

  @override
  Future<KioskSnapshot> snapshot() async => KioskSnapshot(
    supported: true,
    deviceOwner: false,
    permitted: false,
    lockState: KioskLockState.none,
    resumed: true,
    focused: true,
    eligibleWindow: true,
  );

  @override
  Future<KioskIntent> prepare(KioskAction action) async =>
      throw StateError('policy_write_forbidden');

  @override
  Future<KioskReceipt> execute(KioskIntent intent) async {
    policyWrites += 1;
    throw StateError('policy_write_forbidden');
  }

  @override
  Future<void> cancel(KioskIntent intent) async {}
}

Future<void> _waitForWidget(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (target.evaluate().isNotEmpty) return;
  }
  final visibleText = tester
      .widgetList<Text>(find.byType(Text))
      .map((value) => value.data)
      .whereType<String>()
      .join(' | ');
  throw StateError('widget_network_did_not_settle: $visibleText');
}

Future<K09MqttPublication> _waitForPublication(
  WidgetTester tester,
  K09TlsMqttFixture fixture,
  bool Function(K09MqttPublication value) predicate,
) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    final matching = fixture.publications.where(predicate);
    if (matching.isNotEmpty) return matching.first;
  }
  throw StateError('mqtt_publication_did_not_settle');
}

void main() {
  final root = Platform.environment['LARENOR_K09_CORE_URL'];
  late K09TlsMqttFixture fixture;
  late ServerAccountController account;
  late _CredentialStore store;
  late _ObservedSource source;
  late ManagedTabletRuntimeOwner owner;
  late _ReadOnlyKioskApi kiosk;
  late String pairingId, mqttClientId, token;
  var routeCurrent = true;

  setUpAll(() async {
    HttpOverrides.global = null;
    if (root == null) return;
    fixture = await K09TlsMqttFixture.start();
    SharedPreferences.setMockInitialValues({
      SharedPreferencesManagedTabletMqttSettingsStore.preferenceKey: jsonEncode(
        {
          'schemaVersion': 1,
          'enabled': true,
          'host': InternetAddress.loopbackIPv4.address,
          'port': fixture.port,
          'tls': true,
        },
      ),
    });
    account = ServerAccountController(store: _NoSessionStore());
    await account.signIn(
      baseUrl: root,
      username: 'admin',
      password: 'Synthetic new password 2026',
      deviceName: 'K09 actual controlled view',
    );
    expect(account.failure, isNull);
    final remote = CoreKioskRemoteApi(
      account: account,
      sessionRevision: 1,
      routeRevision: 1,
      isCurrent: () => routeCurrent,
    );
    final devices = await remote.load();
    expect(devices.devices, hasLength(1));
    final created = await remote.create(devices.devices.single, const {'read'});
    final session = account.session!;
    final context = session.context!;
    final pairing = created.pairing;
    pairingId = pairing.id;
    mqttClientId = pairing.mqttClientId;
    token = created.token;
    final enrollment = ManagedTabletEnrollment(
      serverBaseUrl: session.endpoint.baseUrl,
      coreId: context.coreId,
      homeId: context.homeId,
      accountId: session.user.id,
      pairingId: pairing.id,
      deviceId: pairing.deviceId,
      revision: pairing.revision,
      scopes: pairing.scopes.toSet(),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        pairing.expiresAtMs,
        isUtc: true,
      ),
      token: created.token,
      clientId: pairing.mqttClientId,
      topicPrefix: pairing.mqttTopicPrefix,
    );
    store = _CredentialStore(enrollment);
    source = _ObservedSource();
    owner = ManagedTabletRuntimeOwner(
      store: store,
      authority: CoreManagedTabletAuthority(),
      source: source,
      broker: MqttClientLocalBroker(securityContext: fixture.clientContext),
      settings: LocalMqttBrokerSettings(
        enabled: true,
        host: InternetAddress.loopbackIPv4.address,
        port: fixture.port,
        tls: true,
      ),
      stateStore: MemoryManagedMqttStateStore(),
      now: DateTime.now,
    );
    await owner.updateBinding(enrollment.binding);
    kiosk = _ReadOnlyKioskApi();
  });

  tearDownAll(() async {
    if (root == null) return;
    routeCurrent = false;
    account.dispose();
    await owner.dispose().timeout(const Duration(seconds: 10));
    await fixture.close().timeout(const Duration(seconds: 10));
  });

  testWidgets(
    'actual Kiosk route publishes bounded frames through normal Core authority and owned TLS MQTT',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      expect(fixture.sessions, hasLength(1));
      expect(fixture.sessions.single.clientId, mqttClientId);
      expect(fixture.sessions.single.username, pairingId);
      expect(fixture.sessions.single.password, token);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            kioskApiProvider.overrideWithValue(kiosk),
            serverAccountControllerProvider.overrideWithValue(account),
            managedTabletCredentialStoreProvider.overrideWithValue(store),
            managedTabletRuntimeOwnerProvider.overrideWithValue(owner),
          ],
          child: ManagedTabletRuntimeScope(
            child: CupertinoApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) =>
                  AppInteractionScope(controller: interaction, child: child!),
              home: const KioskScreen(),
            ),
          ),
        ),
      );
      final open = find.byKey(const ValueKey('kiosk-controlled-view-open'));
      await _waitForWidget(tester, open);

      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final start = find.text('Start app view');
      await _waitForWidget(tester, start);
      expect(find.byType(KioskControlledViewScreen), findsOneWidget);
      expect(
        find.textContaining('MediaProjection is separate and unavailable'),
        findsOneWidget,
      );

      await tester.ensureVisible(start);
      await tester.pump();
      final startButton = find.ancestor(
        of: start,
        matching: find.byType(CupertinoButton),
      );
      expect(startButton, findsOneWidget);
      expect(tester.widget<CupertinoButton>(startButton).onPressed, isNotNull);
      await tester.tap(startButton);
      await tester.pump();
      await _waitForWidget(tester, find.byType(CupertinoAlertDialog));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(
        find.textContaining('Only the marked device information'),
        findsOneWidget,
      );
      await tester.tap(
        find.widgetWithText(CupertinoDialogAction, 'Start sharing'),
      );
      await tester.pump();
      await _waitForWidget(tester, find.text('App view is active'));
      await tester.pump(const Duration(milliseconds: 500));

      final active = (await tester.runAsync(
        () => fixture.waitFor(
          (value) =>
              value.topic.endsWith('/remote_view/receipt') &&
              value.json()['status'] == 'active',
        ),
      ))!;
      final frame = await _waitForPublication(
        tester,
        fixture,
        (value) => value.topic.endsWith('/remote_view/frame'),
      );
      final activeBody = active.json(), frameBody = frame.json();
      expect(active.retained, isFalse);
      expect(frame.retained, isFalse);
      expect(frameBody['requestId'], activeBody['requestId']);
      expect(frameBody['sequence'], 1);
      final png = base64Decode(frameBody['payload'] as String);
      expect(
        png.length,
        lessThanOrEqualTo(managedTabletRemoteViewMaxFrameBytes),
      );
      expect(png.take(8), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      expect(kiosk.policyWrites, 0);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();

      final back = find.byType(CupertinoNavigationBarBackButton);
      expect(back, findsOneWidget);
      await tester.tap(back);
      await tester.pump();
      final retired = await _waitForPublication(
        tester,
        fixture,
        (value) =>
            value.topic.endsWith('/remote_view/receipt') &&
            value.json()['status'] == 'retired' &&
            value.json()['requestId'] == activeBody['requestId'],
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(find.byType(KioskControlledViewScreen), findsNothing);
      expect(retired.retained, isFalse);
      final frameCountAfterRouteRetirement = fixture.publications
          .where((value) => value.topic.endsWith('/remote_view/frame'))
          .length;
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(
        fixture.publications
            .where((value) => value.topic.endsWith('/remote_view/frame'))
            .length,
        frameCountAfterRouteRetirement,
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.runAsync(() => fixture.waitForDisconnects(1));
      routeCurrent = false;
      await tester.runAsync(
        () => owner.updateBinding(null).timeout(const Duration(seconds: 5)),
      );
      expect(source.retires, greaterThan(0));
      expect(kiosk.policyWrites, 0);
    },
    skip: root == null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
