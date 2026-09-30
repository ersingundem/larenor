import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/mesh_center/data/mesh_center_management_api.dart';
import 'package:larenor/features/mesh_center/data/mesh_center_management_controller.dart';
import 'package:larenor/features/mesh_center/domain/mesh_center_models.dart';
import 'package:larenor/features/mesh_center/presentation/mesh_center_management_screen.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _authority = MeshClientAuthority(
  coreId: 'core-main',
  homeId: 'home-a',
  accountId: 'account-admin',
  sessionFamilyId: 'family-a',
  routeId: 'mesh-center',
  homeRevision: 4,
  accountRevision: 8,
  memberRevision: 6,
  sessionRevision: 3,
  routeRevision: 2,
  admin: true,
  canUpdate: true,
);

const _threadAuthority = ThreadDiagnosticsClientAuthority(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: '33333333333333333333333333333333',
  sessionFamilyId: '44444444444444444444444444444444',
  routeId: '55555555555555555555555555555555',
  sessionRevision: 3,
  routeRevision: 2,
  admin: true,
);

MeshCenterSnapshot _snapshot({bool reachable = true}) => MeshCenterSnapshot(
  authority: _authority,
  topologyRevision: 'topology-r8',
  topologyProviderRevision: 'provider-r5',
  coordinatorRevision: 'coordinator-r3',
  interferenceRevision: 'interference-r4',
  capturedAt: DateTime.utc(2026, 9, 21, 10),
  health: MeshHealthState.degraded,
  coordinatorOnline: true,
  channel: 20,
  interferenceAvailable: true,
  recommendedChannel: 15,
  channelUtilizationPercent: 84,
  recommendedUtilizationPercent: 22,
  borderRouterCount: 1,
  offlineBorderRouterCount: 0,
  devices: [
    MeshClientDevice(
      deviceId: 'lamp-a',
      name: 'Living room lamp',
      deviceRevision: 'device-r7',
      expectedResultRevision: 'device-r8',
      providerRevision: 'provider-r5',
      routeRevision: 'route-r6',
      protocol: MeshProtocol.zigbee,
      manufacturer: 'Acme',
      model: 'Lamp 1',
      hardwareRevision: 'hw-r2',
      installedVersion: '1.0.0',
      powerSource: MeshPowerSource.mains,
      batteryPercent: null,
      reachable: reachable,
      updating: false,
      routeKnown: true,
      routeDepth: 2,
      lastSeenAt: DateTime.utc(2026, 9, 21, 10),
      update: MeshFirmwareOffer(
        catalogId: 'catalog-main',
        catalogRevision: 'catalog-r9',
        catalogProviderRevision: 'catalog-provider-r4',
        firmwareId: 'firmware-lamp-2',
        targetVersion: '1.1.0',
        firmwareSha256: 'a' * 64,
        signedMetadataVerified: true,
        compatible: true,
        expiresAt: DateTime.utc(2030),
      ),
    ),
  ],
);

final class _Api implements MeshCenterManagementApi {
  MeshCenterSnapshot value = _snapshot();
  Completer<MeshCenterSnapshot>? loadGate;
  Completer<MeshFirmwareUpdateResult>? confirmGate;
  var previewCalls = 0;
  var confirmCalls = 0;
  var readbackCalls = 0;
  var corruptReadback = false;
  MeshFirmwareUpdatePreview? lastPreview;

  @override
  Future<MeshCenterSnapshot> load(MeshClientAuthority authority) =>
      loadGate?.future ?? Future.value(value);

  @override
  Future<MeshFirmwareUpdatePreview> preview(
    MeshClientAuthority authority, {
    required MeshCenterSnapshot snapshot,
    required MeshClientDevice device,
    required MeshFirmwareOffer firmware,
  }) async {
    previewCalls++;
    return lastPreview = MeshFirmwareUpdatePreview(
      authority: authority,
      requestId: '0123456789abcdef0123456789abcdef',
      topologyRevision: snapshot.topologyRevision,
      topologyProviderRevision: snapshot.topologyProviderRevision,
      coordinatorRevision: snapshot.coordinatorRevision,
      deviceId: device.deviceId,
      expectedDeviceRevision: device.deviceRevision,
      expectedResultRevision: device.expectedResultRevision,
      expectedProviderRevision: device.providerRevision,
      expectedRouteRevision: device.routeRevision,
      catalogId: firmware.catalogId,
      catalogRevision: firmware.catalogRevision,
      catalogProviderRevision: firmware.catalogProviderRevision,
      firmwareId: firmware.firmwareId,
      firmwareSha256: firmware.firmwareSha256,
      targetVersion: firmware.targetVersion,
      expiresAt: DateTime.utc(2030),
      confirmationProof: 'b' * 64,
    );
  }

  MeshFirmwareUpdateResult _result(MeshFirmwareUpdatePreview preview) =>
      MeshFirmwareUpdateResult(
        authority: _authority,
        requestId: preview.requestId,
        deviceId: preview.deviceId,
        previousDeviceRevision: preview.expectedDeviceRevision,
        deviceRevision: preview.expectedResultRevision,
        providerRevision: preview.expectedProviderRevision,
        routeRevision: preview.expectedRouteRevision,
        installedVersion: preview.targetVersion,
        installedSha256: preview.firmwareSha256,
        status: MeshUpdateStatus.confirmed,
        readbackVerified: true,
      );

  @override
  Future<MeshFirmwareUpdateResult> confirm(
    MeshClientAuthority authority,
    MeshFirmwareUpdatePreview preview,
  ) {
    confirmCalls++;
    return confirmGate?.future ?? Future.value(_result(preview));
  }

  @override
  Future<MeshFirmwareUpdateResult> readback(
    MeshClientAuthority authority, {
    required String requestId,
  }) async {
    readbackCalls++;
    if (corruptReadback) {
      final value = _result(lastPreview!);
      return MeshFirmwareUpdateResult(
        authority: value.authority,
        requestId: value.requestId,
        deviceId: value.deviceId,
        previousDeviceRevision: value.previousDeviceRevision,
        deviceRevision: value.deviceRevision,
        providerRevision: value.providerRevision,
        routeRevision: 'foreign-route',
        installedVersion: value.installedVersion,
        installedSha256: value.installedSha256,
        status: value.status,
        readbackVerified: value.readbackVerified,
      );
    }
    return _result(lastPreview!);
  }
}

MeshCenterSnapshot _managedSnapshot() => MeshCenterSnapshot(
  authority: _authority,
  topologyRevision: '22',
  topologyProviderRevision: '22',
  coordinatorRevision: '22',
  interferenceRevision: '22',
  capturedAt: DateTime.utc(2026, 9, 21, 10),
  health: MeshHealthState.healthy,
  coordinatorOnline: true,
  channel: 15,
  interferenceAvailable: false,
  recommendedChannel: null,
  channelUtilizationPercent: null,
  recommendedUtilizationPercent: null,
  borderRouterCount: 0,
  offlineBorderRouterCount: 0,
  devices: [
    MeshClientDevice(
      deviceId: 'lamp-a',
      name: 'Living room lamp',
      deviceRevision: '22',
      expectedResultRevision: '23',
      providerRevision: '22',
      routeRevision: '22',
      protocol: MeshProtocol.zigbee,
      manufacturer: 'Acme',
      model: 'Lamp 1',
      hardwareRevision: 'hw-r2',
      installedVersion: null,
      powerSource: MeshPowerSource.battery,
      batteryPercent: 84,
      reachable: true,
      updating: false,
      routeKnown: false,
      routeDepth: null,
      lastSeenAt: DateTime.utc(2026, 9, 21, 10),
      update: null,
    ),
  ],
);

final class _ManagedApi
    implements
        MeshCenterManagementApi,
        ManagedOtaManagementApi,
        ThreadDiagnosticsManagementApi {
  final snapshot = _managedSnapshot();
  var checks = 0;
  var previews = 0;
  var confirms = 0;
  var readbacks = 0;
  var waits = 0;
  var threadConfigs = 0;
  var threadSaves = 0;
  var threadReads = 0;
  var meshLoadFails = false;
  var uncertain = false;
  var confirmTimesOut = false;
  MeshManagedOtaPreview? lastPreview;
  ThreadDiagnosticsBinding? threadBinding;
  final threadService = const ThreadServiceOption(
    serviceId: 'c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9',
    serviceRevision: 4,
    name: 'Home Assistant',
  );

  @override
  Future<MeshCenterSnapshot> load(MeshClientAuthority authority) async {
    if (meshLoadFails) {
      throw const LarenorServerException('mesh_provider_unavailable');
    }
    return snapshot;
  }

  @override
  Future<MeshManagedOtaAvailability> checkManagedOta(
    MeshClientAuthority authority, {
    required MeshCenterSnapshot snapshot,
    required MeshClientDevice device,
  }) async {
    checks++;
    return MeshManagedOtaAvailability(
      snapshot: this.snapshot,
      device: this.snapshot.devices.single,
      offer: MeshManagedOtaOffer(
        offerId: 'e' * 32,
        deviceId: device.deviceId,
        topologyRevision: '22',
        providerRevision: '22',
        deviceRevision: '22',
        installedFileVersion: 5,
        latestFileVersion: 10,
        providerSourceDigest: 'f' * 64,
        checkedAt: DateTime.utc(2026, 9, 21, 10),
        expiresAt: DateTime.utc(2030),
        releaseNotesAvailable: true,
      ),
    );
  }

  @override
  Future<MeshManagedOtaPreview> previewManagedOta(
    MeshClientAuthority authority,
    MeshManagedOtaAvailability availability,
  ) async {
    previews++;
    return lastPreview = MeshManagedOtaPreview(
      authority: authority,
      requestId: 'a' * 32,
      deviceId: availability.device.deviceId,
      topologyRevision: '22',
      providerRevision: '22',
      deviceRevision: '22',
      offerId: availability.offer.offerId,
      installedFileVersion: 5,
      latestFileVersion: 10,
      providerSourceDigest: availability.offer.providerSourceDigest,
      expiresAt: DateTime.utc(2030),
      confirmationProof: 'b' * 64,
    );
  }

  MeshManagedOtaResult _result(MeshManagedOtaPreview preview) =>
      MeshManagedOtaResult(
        requestId: preview.requestId,
        status: uncertain
            ? MeshUpdateStatus.uncertain
            : MeshUpdateStatus.confirmed,
        reason: uncertain ? 'lost_ack' : 'installed',
        readbackVerified: !uncertain,
        previousProviderRevision: uncertain ? null : '22',
        providerRevision: uncertain ? null : '23',
        installedFileVersion: uncertain ? null : 10,
        completedAt: uncertain ? null : DateTime.utc(2026, 9, 21, 10, 2),
      );

  @override
  Future<MeshManagedOtaResult> confirmManagedOta(
    MeshClientAuthority authority,
    MeshManagedOtaPreview preview,
  ) async {
    confirms++;
    if (confirmTimesOut) {
      throw const LarenorServerException('timeout');
    }
    return _result(preview);
  }

  @override
  Future<MeshManagedOtaResult> readbackManagedOta(
    MeshClientAuthority authority, {
    required String requestId,
  }) async {
    readbacks++;
    return _result(lastPreview!);
  }

  @override
  Future<MeshManagedOtaResult> awaitManagedOtaResult(
    MeshClientAuthority authority, {
    required String requestId,
  }) async {
    waits++;
    return readbackManagedOta(authority, requestId: requestId);
  }

  @override
  Future<ThreadDiagnosticsConfiguration> loadThreadConfiguration(
    ThreadDiagnosticsClientAuthority authority,
  ) async {
    threadConfigs++;
    return ThreadDiagnosticsConfiguration(
      binding: threadBinding,
      services: [threadService],
    );
  }

  @override
  Future<ThreadDiagnosticsBinding> configureThreadDiagnostics(
    ThreadDiagnosticsClientAuthority authority, {
    required ThreadServiceOption service,
    required int? expectedRevision,
  }) async {
    threadSaves++;
    return threadBinding = ThreadDiagnosticsBinding(
      revision: (expectedRevision ?? 0) + 1,
      serviceId: service.serviceId,
      serviceRevision: service.serviceRevision,
    );
  }

  @override
  Future<ThreadDiagnosticsSnapshot> loadThreadDiagnostics(
    ThreadDiagnosticsClientAuthority authority,
  ) async {
    threadReads++;
    return ThreadDiagnosticsSnapshot(
      bindingRevision: threadBinding!.revision,
      serviceId: threadBinding!.serviceId,
      serviceRevision: threadBinding!.serviceRevision,
      capturedAt: DateTime.utc(2026, 9, 21, 10, 1),
      datasets: const [
        ThreadDatasetSummary(
          datasetId: 'd9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9',
          networkName: 'Home Thread',
          channel: 15,
          preferred: true,
          source: 'otbr',
        ),
      ],
      routers: const [
        ThreadRouterSummary(
          routerId: 'e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9',
          networkName: 'Home Thread',
          brand: 'homeassistant',
          modelName: 'OTBR',
          threadVersion: '1.3.0',
          vendorName: 'Home Assistant',
          unconfigured: false,
        ),
      ],
    );
  }

  @override
  Future<MeshFirmwareUpdatePreview> preview(
    MeshClientAuthority authority, {
    required MeshCenterSnapshot snapshot,
    required MeshClientDevice device,
    required MeshFirmwareOffer firmware,
  }) => throw StateError('signed catalog path is not used');

  @override
  Future<MeshFirmwareUpdateResult> confirm(
    MeshClientAuthority authority,
    MeshFirmwareUpdatePreview preview,
  ) => throw StateError('signed catalog path is not used');

  @override
  Future<MeshFirmwareUpdateResult> readback(
    MeshClientAuthority authority, {
    required String requestId,
  }) => throw StateError('signed catalog path is not used');
}

void main() {
  test(
    'provider-managed OTA checks, confirms once, and verifies readback',
    () async {
      final api = _ManagedApi();
      final controller = MeshCenterManagementController(
        api: api,
        authority: _authority,
        threadAuthority: _threadAuthority,
        isCurrent: () => true,
        clock: () => DateTime.utc(2026, 9, 21, 10, 1),
      );
      addTearDown(controller.dispose);

      await controller.load();
      final device = controller.snapshot!.devices.single;
      expect(device.routeKnown, isFalse);
      expect(controller.canCheckManagedUpdate(device), isTrue);
      await controller.previewManagedUpdate(device);
      expect(controller.pendingManagedPreview?.latestFileVersion, 10);
      expect(api.checks, 1);
      expect(api.previews, 1);
      await controller.confirmPending();
      expect(controller.state, MeshCenterManagementState.verified);
      expect(api.confirms, 1);
      expect(api.readbacks, 1);
      expect(api.waits, 1);

      api.uncertain = true;
      await controller.load();
      await controller.previewManagedUpdate(
        controller.snapshot!.devices.single,
      );
      await controller.confirmPending();
      expect(controller.state, MeshCenterManagementState.failed);
      expect(controller.lastManagedResult?.status, MeshUpdateStatus.uncertain);
      await controller.confirmPending();
      expect(api.confirms, 2);
    },
  );

  test(
    'managed OTA timeout polls durable result without resending confirm',
    () async {
      final api = _ManagedApi()..confirmTimesOut = true;
      final controller = MeshCenterManagementController(
        api: api,
        authority: _authority,
        threadAuthority: _threadAuthority,
        isCurrent: () => true,
        clock: () => DateTime.utc(2026, 9, 21, 10, 1),
      );
      addTearDown(controller.dispose);

      await controller.load();
      await controller.previewManagedUpdate(
        controller.snapshot!.devices.single,
      );
      await controller.confirmPending();

      expect(controller.state, MeshCenterManagementState.verified);
      expect(api.confirms, 1);
      expect(api.waits, 1);
      expect(api.readbacks, 1);
    },
  );

  testWidgets('provider-managed OTA requires an explicit user confirmation', (
    tester,
  ) async {
    final api = _ManagedApi();
    final controller = MeshCenterManagementController(
      api: api,
      authority: _authority,
      threadAuthority: _threadAuthority,
      isCurrent: () => true,
      clock: () => DateTime.utc(2026, 9, 21, 10, 1),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      CupertinoApp(home: MeshCenterManagementScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('mesh-update-lamp-a')));
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(find.textContaining('Zigbee2MQTT'), findsOneWidget);
    expect(api.confirms, 0);
    await tester.tap(find.byKey(const ValueKey('mesh-confirm-update')));
    await tester.pumpAndSettle();
    expect(api.confirms, 1);
    expect(api.readbacks, 1);
  });

  testWidgets('admin selects verified HA source and reads Thread diagnostics', (
    tester,
  ) async {
    final api = _ManagedApi();
    final controller = MeshCenterManagementController(
      api: api,
      authority: _authority,
      threadAuthority: _threadAuthority,
      isCurrent: () => true,
      clock: () => DateTime.utc(2026, 9, 21, 10, 2),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      CupertinoApp(home: MeshCenterManagementScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Select Home Assistant connection'), findsOneWidget);
    final configure = find.byKey(
      const ValueKey('thread-diagnostics-configure'),
    );
    await tester.ensureVisible(configure);
    await tester.tap(configure);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home Assistant').last);
    await tester.pumpAndSettle();

    expect(api.threadSaves, 1);
    expect(api.threadReads, 1);
    expect(find.textContaining('Home Thread · 15'), findsOneWidget);
    expect(find.textContaining('1 border routers'), findsOneWidget);
  });

  testWidgets(
    'Thread diagnostics remain configurable while Zigbee observation fails',
    (tester) async {
      final api = _ManagedApi()..meshLoadFails = true;
      final controller = MeshCenterManagementController(
        api: api,
        authority: _authority,
        threadAuthority: _threadAuthority,
        isCurrent: () => true,
        clock: () => DateTime.utc(2026, 9, 21, 10, 2),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        CupertinoApp(home: MeshCenterManagementScreen(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(controller.state, MeshCenterManagementState.failed);
      expect(controller.snapshot, isNull);
      expect(api.threadConfigs, 1);
      final configure = find.byKey(
        const ValueKey('thread-diagnostics-configure'),
      );
      expect(configure, findsOneWidget);
      await tester.ensureVisible(configure);
      await tester.tap(configure);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Home Assistant').last);
      await tester.pumpAndSettle();

      expect(api.threadSaves, 1);
      expect(api.threadReads, 1);
      expect(find.textContaining('Home Thread · 15'), findsOneWidget);
    },
  );

  test(
    'topology and update state are exact, advisory, and stale-safe',
    () async {
      var current = true;
      final api = _Api();
      final controller = MeshCenterManagementController(
        api: api,
        authority: _authority,
        threadAuthority: _threadAuthority,
        isCurrent: () => current,
        clock: () => DateTime.utc(2026, 9, 21, 10, 1),
      );
      addTearDown(controller.dispose);

      await controller.load();
      final snapshot = controller.snapshot!;
      expect(snapshot.channelAdviceReadOnly, isTrue);
      expect(snapshot.devices.single.update!.signedMetadataVerified, isTrue);
      expect(snapshot.toString(), isNot(contains('signature')));

      api.value = _snapshot(reachable: false);
      await controller.load();
      await controller.previewUpdate(controller.snapshot!.devices.single);
      expect(api.previewCalls, 0);

      final gate = Completer<MeshCenterSnapshot>();
      api.loadGate = gate;
      final late = controller.load();
      current = false;
      gate.complete(_snapshot());
      await late;
      expect(controller.snapshot, isNull);
      expect(controller.state, MeshCenterManagementState.stale);
    },
  );

  test(
    'firmware update requires confirmation and exact verified readback',
    () async {
      var current = true;
      final api = _Api();
      final controller = MeshCenterManagementController(
        api: api,
        authority: _authority,
        threadAuthority: _threadAuthority,
        isCurrent: () => current,
        clock: () => DateTime.utc(2026, 9, 21, 10, 1),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.previewUpdate(controller.snapshot!.devices.single);
      expect(controller.pendingPreview, isNotNull);
      expect(api.confirmCalls, 0);

      final gate = Completer<MeshFirmwareUpdateResult>();
      api.confirmGate = gate;
      final late = controller.confirmPending();
      current = false;
      gate.complete(api._result(api.lastPreview!));
      await late;
      expect(controller.state, MeshCenterManagementState.stale);
      expect(api.readbackCalls, 0);

      current = true;
      api.confirmGate = null;
      api.corruptReadback = true;
      await controller.load();
      await controller.previewUpdate(controller.snapshot!.devices.single);
      await controller.confirmPending();
      expect(controller.state, MeshCenterManagementState.failed);
      expect(controller.lastResult, isNull);

      api.corruptReadback = false;
      await controller.load();
      await controller.previewUpdate(controller.snapshot!.devices.single);
      await controller.confirmPending();
      expect(controller.state, MeshCenterManagementState.verified);
      expect(controller.lastResult!.readbackVerified, isTrue);
      expect(api.confirmCalls, 3);
      expect(api.readbackCalls, 2);
    },
  );

  for (final language in ['en', 'tr']) {
    for (final size in [const Size(600, 900), const Size(1280, 900)]) {
      testWidgets(
        '$language mesh center is accessible at ${size.width}px and 2x',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final semantics = tester.ensureSemantics();
          final api = _Api();
          final controller = MeshCenterManagementController(
            api: api,
            authority: _authority,
            isCurrent: () => true,
            clock: () => DateTime.utc(2026, 9, 21, 10, 1),
          );
          addTearDown(controller.dispose);

          await tester.pumpWidget(
            CupertinoApp(
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: MeshCenterManagementScreen(controller: controller),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(2));
          final action = find.byKey(const ValueKey('mesh-update-lamp-a'));
          expect(tester.getRect(action).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(action).flagsCollection.isButton, isTrue);
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('mesh-topology-status')),
                )
                .label,
            contains(language == 'tr' ? 'Salt okunur' : 'Read-only'),
          );
          expect(tester.takeException(), isNull);

          Focus.of(
            tester.element(
              find.descendant(of: action, matching: find.byType(Text)),
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(CupertinoAlertDialog), findsOneWidget);
          expect(api.confirmCalls, 0);

          final confirm = find.byKey(const ValueKey('mesh-confirm-update'));
          expect(tester.getRect(confirm).height, greaterThanOrEqualTo(48));
          Focus.of(
            tester.element(
              find.descendant(of: confirm, matching: find.byType(Text)),
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(api.confirmCalls, 1);
          expect(api.readbackCalls, 1);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }
}
