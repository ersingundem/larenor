import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/mesh_center/data/mesh_center_management_api.dart';
import 'package:larenor/features/mesh_center/data/mesh_center_management_controller.dart';
import 'package:larenor/features/mesh_center/domain/mesh_center_models.dart';
import 'package:larenor/features/mesh_center/presentation/mesh_center_management_screen.dart';
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
    return _result(lastPreview!);
  }
}

void main() {
  test('topology and update state are exact, advisory, and stale-safe', () async {
    var current = true;
    final api = _Api();
    final controller = MeshCenterManagementController(
      api: api,
      authority: _authority,
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
  });

  test('firmware update requires confirmation and exact verified readback', () async {
    var current = true;
    final api = _Api();
    final controller = MeshCenterManagementController(
      api: api,
      authority: _authority,
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
    await controller.load();
    await controller.previewUpdate(controller.snapshot!.devices.single);
    await controller.confirmPending();
    expect(controller.state, MeshCenterManagementState.verified);
    expect(controller.lastResult!.readbackVerified, isTrue);
    expect(api.confirmCalls, 2);
    expect(api.readbackCalls, 1);
  });

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
              localizationsDelegates:
                  AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                ),
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
