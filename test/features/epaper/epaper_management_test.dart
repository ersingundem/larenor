import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/epaper/data/epaper_management_api.dart';
import 'package:larenor/features/epaper/data/epaper_management_controller.dart';
import 'package:larenor/features/epaper/domain/epaper_management_models.dart';
import 'package:larenor/features/epaper/presentation/epaper_management_screen.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _authority = EpaperClientAuthority(
  coreId: 'core-main',
  homeId: 'home-a',
  accountId: 'account-admin',
  sessionFamilyId: 'session-family-a',
  homeRevision: 4,
  accountRevision: 8,
  sessionRevision: 3,
);

EpaperDeviceStatus _device({
  EpaperSnapshotTrust trust = EpaperSnapshotTrust.verified,
  bool stored = true,
  bool reachable = true,
  String layoutRevision = 'layout-r4',
}) => EpaperDeviceStatus(
  authority: _authority,
  deviceId: 'hall-display',
  name: 'Hall display',
  deviceRevision: 'device-r7',
  bridgeRevision: 'bridge-r2',
  layoutRevision: layoutRevision,
  dataRevision: 'data-r9',
  policyRevision: 'policy-r5',
  stored: stored,
  reachable: reachable,
  snapshotTrust: trust,
  snapshotDigest: trust == EpaperSnapshotTrust.empty ? null : 'a' * 64,
  verifiedDigest: trust == EpaperSnapshotTrust.verified ? 'a' * 64 : null,
  expiresAt: DateTime.utc(2030),
);

final class _Api implements EpaperManagementApi {
  List<EpaperDeviceStatus> devices = [_device()];
  Completer<List<EpaperDeviceStatus>>? listGate;
  Completer<EpaperCommandReceipt>? confirmGate;
  var previewCalls = 0;
  var confirmCalls = 0;
  var readbackCalls = 0;

  @override
  Future<List<EpaperDeviceStatus>> list(EpaperClientAuthority authority) =>
      listGate?.future ?? Future.value(devices);

  @override
  Future<EpaperCommandPreview> preview(
    EpaperClientAuthority authority, {
    required String deviceId,
    required String expectedDeviceRevision,
    required EpaperManagementAction action,
  }) async {
    previewCalls++;
    return EpaperCommandPreview(
      authority: authority,
      requestId: '0123456789abcdef0123456789abcdef',
      deviceId: deviceId,
      deviceRevision: expectedDeviceRevision,
      action: action,
      expectedLayoutRevision:
          action == EpaperManagementAction.rotate ? 'layout-r5' : 'layout-r4',
      expiresAt: DateTime.utc(2030),
    );
  }

  @override
  Future<EpaperCommandReceipt> confirm(
    EpaperClientAuthority authority,
    EpaperCommandPreview preview,
  ) {
    confirmCalls++;
    return confirmGate?.future ??
        Future.value(
          EpaperCommandReceipt(
            authority: authority,
            requestId: preview.requestId,
            deviceId: preview.deviceId,
            deviceRevision: preview.deviceRevision,
            action: preview.action,
            status: EpaperCommandStatus.applied,
            observedLayoutRevision: preview.expectedLayoutRevision,
            observedSnapshotDigest: 'a' * 64,
          ),
        );
  }

  @override
  Future<EpaperDeviceStatus> readback(
    EpaperClientAuthority authority, {
    required String deviceId,
  }) async {
    readbackCalls++;
    final pending = devices.single;
    return pending.copyWith(
      layoutRevision: previewLayout,
      snapshotTrust: EpaperSnapshotTrust.verified,
      snapshotDigest: 'a' * 64,
      verifiedDigest: 'a' * 64,
    );
  }

  String previewLayout = 'layout-r4';
}

void main() {
  test('safe state is exact-authority bound and stale loads fail closed', () async {
    var current = true;
    final api = _Api();
    final controller = EpaperManagementController(
      api: api,
      authority: _authority,
      isCurrent: () => current,
    );
    addTearDown(controller.dispose);

    await controller.load();
    expect(controller.devices.single.stored, isTrue);
    expect(controller.devices.single.reachable, isTrue);
    expect(
      controller.devices.single.snapshotTrust,
      EpaperSnapshotTrust.verified,
    );

    final gate = Completer<List<EpaperDeviceStatus>>();
    api.listGate = gate;
    final late = controller.load();
    current = false;
    gate.complete([_device(trust: EpaperSnapshotTrust.partial)]);
    await late;

    expect(controller.devices, isEmpty);
    expect(controller.state, EpaperManagementState.stale);
  });

  test('refresh and rotate require confirmation plus exact verified readback', () async {
    var current = true;
    final api = _Api();
    final controller = EpaperManagementController(
      api: api,
      authority: _authority,
      isCurrent: () => current,
    );
    addTearDown(controller.dispose);
    await controller.load();

    await controller.preview(
      controller.devices.single,
      EpaperManagementAction.rotate,
    );
    expect(controller.pendingPreview, isNotNull);
    expect(api.confirmCalls, 0);

    api.previewLayout = 'layout-r5';
    final gate = Completer<EpaperCommandReceipt>();
    api.confirmGate = gate;
    final late = controller.confirmPending();
    current = false;
    gate.complete(
      EpaperCommandReceipt(
        authority: _authority,
        requestId: controller.pendingPreview!.requestId,
        deviceId: 'hall-display',
        deviceRevision: 'device-r7',
        action: EpaperManagementAction.rotate,
        status: EpaperCommandStatus.applied,
        observedLayoutRevision: 'layout-r5',
        observedSnapshotDigest: 'a' * 64,
      ),
    );
    await late;
    expect(controller.state, EpaperManagementState.stale);
    expect(api.readbackCalls, 0);

    current = true;
    api.confirmGate = null;
    await controller.load();
    await controller.preview(
      controller.devices.single,
      EpaperManagementAction.rotate,
    );
    await controller.confirmPending();
    expect(controller.state, EpaperManagementState.verified);
    expect(controller.devices.single.layoutRevision, 'layout-r5');
    expect(api.confirmCalls, 2);
    expect(api.readbackCalls, 1);
  });

  for (final language in ['en', 'tr']) {
    for (final size in [const Size(600, 900), const Size(1280, 900)]) {
      testWidgets(
        '$language tablet management is accessible at ${size.width}px and 2x',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final semantics = tester.ensureSemantics();
          addTearDown(semantics.dispose);
          final api = _Api();
          final controller = EpaperManagementController(
            api: api,
            authority: _authority,
            isCurrent: () => true,
          );
          addTearDown(controller.dispose);

          await tester.pumpWidget(
            CupertinoApp(
              locale: Locale(language),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                ),
                child: child!,
              ),
              home: EpaperManagementScreen(controller: controller),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(2));
          final refresh = find.byKey(
            const ValueKey('epaper-refresh-hall-display'),
          );
          final rotate = find.byKey(
            const ValueKey('epaper-rotate-hall-display'),
          );
          expect(tester.getRect(refresh).height, greaterThanOrEqualTo(48));
          expect(tester.getRect(rotate).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(refresh).flagsCollection.isButton, isTrue);
          expect(
            tester
                .getSemantics(
                  find.byKey(
                    const ValueKey('epaper-state-hall-display'),
                  ),
                )
                .label,
            contains(language == 'tr' ? 'Doğrulandı' : 'Verified'),
          );

          Focus.of(tester.element(refresh)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(CupertinoAlertDialog), findsOneWidget);
          expect(api.confirmCalls, 0);

          final confirm = find.byKey(const ValueKey('epaper-confirm-action'));
          expect(tester.getRect(confirm).height, greaterThanOrEqualTo(48));
          Focus.of(tester.element(confirm)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(api.confirmCalls, 1);
          expect(api.readbackCalls, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
