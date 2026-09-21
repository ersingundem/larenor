import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/epaper/data/epaper_management_api.dart';
import 'package:larenor/features/epaper/data/epaper_management_controller.dart';
import 'package:larenor/features/epaper/domain/epaper_management_models.dart';
import 'package:larenor/features/epaper/presentation/epaper_management_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
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
  canManage: true,
);

EpaperDeviceStatus _device({
  EpaperSnapshotTrust trust = EpaperSnapshotTrust.acknowledged,
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
  verifiedDigest: null,
  expiresAt: DateTime.utc(2030),
);

final class _Api implements EpaperManagementApi {
  List<EpaperDeviceStatus> devices = [_device()];
  Completer<List<EpaperDeviceStatus>>? listGate;
  Completer<EpaperCommandReceipt>? confirmGate;
  var previewCalls = 0;
  var confirmCalls = 0;
  var readbackCalls = 0;
  var cancelCalls = 0;
  var mapCalls = 0;
  var confirmStatus = EpaperCommandStatus.uncertain;
  var readbackTrust = EpaperSnapshotTrust.acknowledged;

  @override
  Future<EpaperDeviceStatus> map(
    EpaperClientAuthority authority,
    EpaperDeviceMappingDraft draft,
  ) async {
    mapCalls++;
    return EpaperDeviceStatus(
      authority: authority,
      deviceId: draft.deviceId,
      name: draft.name,
      deviceRevision: '1',
      bridgeRevision: '1',
      layoutRevision: '1',
      dataRevision: '1',
      policyRevision: '1',
      stored: true,
      reachable: false,
      snapshotTrust: EpaperSnapshotTrust.pending,
      snapshotDigest: 'b' * 64,
      verifiedDigest: null,
      expiresAt: DateTime.utc(2030),
    );
  }

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
      expectedLayoutRevision: 'layout-r4',
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
            status: confirmStatus,
            observedLayoutRevision: confirmStatus == EpaperCommandStatus.applied
                ? preview.expectedLayoutRevision
                : null,
            observedSnapshotDigest: confirmStatus == EpaperCommandStatus.applied
                ? 'a' * 64
                : null,
          ),
        );
  }

  @override
  Future<void> cancel(
    EpaperClientAuthority authority,
    EpaperCommandPreview preview,
  ) async {
    cancelCalls++;
  }

  @override
  Future<EpaperDeviceStatus> readback(
    EpaperClientAuthority authority, {
    required String deviceId,
  }) async {
    readbackCalls++;
    final pending = devices.single;
    return EpaperDeviceStatus(
      authority: pending.authority,
      deviceId: pending.deviceId,
      name: pending.name,
      deviceRevision: pending.deviceRevision,
      bridgeRevision: pending.bridgeRevision,
      layoutRevision: previewLayout,
      dataRevision: pending.dataRevision,
      policyRevision: pending.policyRevision,
      stored: pending.stored,
      reachable: pending.reachable,
      snapshotTrust: readbackTrust,
      snapshotDigest: 'a' * 64,
      verifiedDigest: null,
      expiresAt: pending.expiresAt,
    );
  }

  String previewLayout = 'layout-r4';
}

void main() {
  test(
    'safe state is exact-authority bound and stale loads fail closed',
    () async {
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
        EpaperSnapshotTrust.acknowledged,
      );

      api.devices = [_device(reachable: false)];
      await controller.load();
      await controller.preview(
        controller.devices.single,
        EpaperManagementAction.refresh,
      );
      expect(api.previewCalls, 0);

      final gate = Completer<List<EpaperDeviceStatus>>();
      api.listGate = gate;
      final late = controller.load();
      current = false;
      gate.complete([_device(trust: EpaperSnapshotTrust.partial)]);
      await late;

      expect(controller.devices, isEmpty);
      expect(controller.state, EpaperManagementState.stale);
    },
  );

  test(
    'published snapshot stays pending until a physical acknowledgement',
    () async {
      final api = _Api()
        ..confirmStatus = EpaperCommandStatus.uncertain
        ..readbackTrust = EpaperSnapshotTrust.pending;
      final controller = EpaperManagementController(
        api: api,
        authority: _authority,
        isCurrent: () => true,
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.preview(
        controller.devices.single,
        EpaperManagementAction.refresh,
      );
      await controller.confirmPending();
      expect(controller.state, EpaperManagementState.pendingDelivery);
      expect(
        controller.devices.single.snapshotTrust,
        EpaperSnapshotTrust.pending,
      );
    },
  );

  test('mapping and cancellation stay admin and operation bound', () async {
    var current = true;
    final api = _Api();
    final controller = EpaperManagementController(
      api: api,
      authority: _authority,
      isCurrent: () => current,
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.map(
      const EpaperDeviceMappingDraft(
        deviceId: 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0',
        name: 'Kitchen display',
      ),
    );
    expect(api.mapCalls, 1);
    expect(
      controller.devices.any((item) => item.name == 'Kitchen display'),
      isTrue,
    );

    await controller.preview(
      controller.devices.firstWhere((item) => item.deviceId == 'hall-display'),
      EpaperManagementAction.refresh,
    );
    await controller.cancelPending();
    expect(api.cancelCalls, 1);
    expect(controller.pendingPreview, isNull);
    expect(controller.state, EpaperManagementState.ready);

    current = false;
    await controller.map(
      const EpaperDeviceMappingDraft(
        deviceId: 'c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0',
        name: 'Late display',
      ),
    );
    expect(api.mapCalls, 1);
  });

  test('refresh remains unverified after exact Core readback', () async {
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
      EpaperManagementAction.refresh,
    );
    expect(controller.pendingPreview, isNotNull);
    expect(api.confirmCalls, 0);

    api.previewLayout = 'layout-r4';
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
        action: EpaperManagementAction.refresh,
        status: EpaperCommandStatus.applied,
        observedLayoutRevision: 'layout-r4',
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
      EpaperManagementAction.refresh,
    );
    await controller.confirmPending();
    expect(controller.state, EpaperManagementState.pendingDelivery);
    expect(controller.devices.single.layoutRevision, 'layout-r4');
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
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
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
          expect(tester.getRect(refresh).height, greaterThanOrEqualTo(48));
          expect(
            tester
                .getRect(find.byKey(const ValueKey('epaper-map-display')))
                .height,
            greaterThanOrEqualTo(48),
          );
          expect(tester.getSemantics(refresh).flagsCollection.isButton, isTrue);
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('epaper-state-hall-display')),
                )
                .label,
            contains(
              language == 'tr' ? 'cihaz doğrulanmadı' : 'device unverified',
            ),
          );

          Focus.of(
            tester.element(
              find.descendant(of: refresh, matching: find.byType(Text)),
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(CupertinoAlertDialog), findsOneWidget);
          expect(api.confirmCalls, 0);

          final confirm = find.byKey(const ValueKey('epaper-confirm-action'));
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

  testWidgets(
    'mapping form is bounded, keyboard reachable, and validates input',
    (tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = _Api();
      final controller = EpaperManagementController(
        api: api,
        authority: _authority,
        isCurrent: () => true,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        CupertinoApp(home: EpaperManagementScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('epaper-map-display')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('epaper-map-device-id')),
        findsOneWidget,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('epaper-map-submit'))).height,
        greaterThanOrEqualTo(48),
      );
      await tester.enterText(
        find.byKey(const ValueKey('epaper-map-device-id')),
        'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0',
      );
      await tester.enterText(
        find.byKey(const ValueKey('epaper-map-name')),
        'Bedroom display',
      );
      final submit = find.byKey(const ValueKey('epaper-map-submit'));
      Focus.of(
        tester.element(
          find.descendant(of: submit, matching: find.byType(Text)),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(api.mapCalls, 1);
    },
  );
}
