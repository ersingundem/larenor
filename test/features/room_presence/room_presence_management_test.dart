import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/room_presence/data/room_presence_management_api.dart';
import 'package:larenor/features/room_presence/data/room_presence_management_controller.dart';
import 'package:larenor/features/room_presence/domain/room_presence_management_models.dart';
import 'package:larenor/features/room_presence/presentation/room_presence_management_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _authority = RoomPresenceClientAuthority(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: '33333333333333333333333333333333',
  sessionFamilyId: '44444444444444444444444444444444',
  routeId: '55555555555555555555555555555555',
  homeRevision: 4,
  accountRevision: 8,
  sessionRevision: 3,
  routeRevision: 2,
);

RoomPresenceEvidence _evidence({
  PresenceEvidenceState state = PresenceEvidenceState.present,
  bool stored = true,
  bool providerReachable = true,
  String calibrationRevision = 'cal-r3',
}) => RoomPresenceEvidence(
  authority: _authority,
  deviceId: '66666666666666666666666666666666',
  deviceName: 'Tablet owner',
  deviceRevision: 'device-r7',
  modelRevision: 'model-r2',
  policyRevision: 'policy-r5',
  consentRevision: 'consent-r4',
  consentActive: true,
  configuredRoomId: '99999999999999999999999999999999',
  configuredRoomName: 'Living room',
  configuredRoomRevision: 'room-r6',
  detectedRoomId:
      state == PresenceEvidenceState.present ||
          state == PresenceEvidenceState.uncertain
      ? '99999999999999999999999999999999'
      : null,
  detectedRoomRevision:
      state == PresenceEvidenceState.present ||
          state == PresenceEvidenceState.uncertain
      ? 'room-r6'
      : null,
  estimateRevision: 'estimate-r9',
  transitionRevision: 12,
  calibrationRevision: calibrationRevision,
  state: state,
  confidencePermille: state == PresenceEvidenceState.unknown ? 0 : 880,
  sampleCount: state == PresenceEvidenceState.unknown ? 0 : 3,
  observedAt: DateTime.utc(2026, 9, 21, 10),
  stored: stored,
  providerReachable: providerReachable,
);

final class _Api implements RoomPresenceManagementApi {
  List<RoomPresenceEvidence> values = [_evidence()];
  Completer<List<RoomPresenceEvidence>>? listGate;
  Completer<PresenceCalibrationReceipt>? confirmGate;
  var previewCalls = 0;
  var confirmCalls = 0;
  var readbackCalls = 0;
  String readbackCalibration = 'cal-r4';

  @override
  Future<List<RoomPresenceEvidence>> list(
    RoomPresenceClientAuthority authority,
  ) => listGate?.future ?? Future.value(values);

  @override
  Future<PresenceCalibrationPreview> previewCalibration(
    RoomPresenceClientAuthority authority, {
    required String deviceId,
    required String expectedDeviceRevision,
    required String expectedModelRevision,
    required String roomId,
    required String expectedRoomRevision,
    required String expectedPolicyRevision,
    required String expectedConsentRevision,
    required String expectedCalibrationRevision,
  }) async {
    previewCalls++;
    return PresenceCalibrationPreview(
      authority: authority,
      requestId: '0123456789abcdef0123456789abcdef',
      deviceId: deviceId,
      deviceRevision: expectedDeviceRevision,
      modelRevision: expectedModelRevision,
      roomId: roomId,
      roomRevision: expectedRoomRevision,
      policyRevision: expectedPolicyRevision,
      consentRevision: expectedConsentRevision,
      previousCalibrationRevision: expectedCalibrationRevision,
      nextCalibrationRevision: 'cal-r4',
      expiresAt: DateTime.utc(2030),
    );
  }

  @override
  Future<PresenceCalibrationReceipt> confirmCalibration(
    RoomPresenceClientAuthority authority,
    PresenceCalibrationPreview preview,
  ) {
    confirmCalls++;
    return confirmGate?.future ??
        Future.value(
          PresenceCalibrationReceipt(
            authority: authority,
            requestId: preview.requestId,
            deviceId: preview.deviceId,
            deviceRevision: preview.deviceRevision,
            modelRevision: preview.modelRevision,
            roomId: preview.roomId,
            roomRevision: preview.roomRevision,
            policyRevision: preview.policyRevision,
            consentRevision: preview.consentRevision,
            previousCalibrationRevision: preview.previousCalibrationRevision,
            observedCalibrationRevision: preview.nextCalibrationRevision,
            status: PresenceCalibrationStatus.applied,
          ),
        );
  }

  @override
  Future<RoomPresenceEvidence> readback(
    RoomPresenceClientAuthority authority, {
    required String deviceId,
  }) async {
    readbackCalls++;
    return values.single.copyWith(calibrationRevision: readbackCalibration);
  }
}

void main() {
  test('older load completion cannot clear a newer verified page', () async {
    final api = _Api();
    final controller = RoomPresenceManagementController(
      api: api,
      authority: _authority,
      isCurrent: () => true,
      clock: () => DateTime.utc(2026, 9, 21, 12),
    );
    addTearDown(controller.dispose);

    final older = Completer<List<RoomPresenceEvidence>>();
    api.listGate = older;
    final olderLoad = controller.load();
    final newer = Completer<List<RoomPresenceEvidence>>();
    api.listGate = newer;
    final newerLoad = controller.load();
    newer.complete([_evidence(state: PresenceEvidenceState.present)]);
    await newerLoad;
    older.complete([_evidence(state: PresenceEvidenceState.uncertain)]);
    await olderLoad;

    expect(controller.state, RoomPresenceManagementState.ready);
    expect(controller.evidence.single.state, PresenceEvidenceState.present);
  });

  test(
    'public room evidence stays private and stale authority clears it',
    () async {
      var current = true;
      final api = _Api();
      final controller = RoomPresenceManagementController(
        api: api,
        authority: _authority,
        isCurrent: () => current,
        clock: () => DateTime.utc(2026, 9, 21, 12),
      );
      addTearDown(controller.dispose);

      await controller.load();
      final value = controller.evidence.single;
      expect(value.advisoryOnly, isTrue);
      expect(value.grantsAccess, isFalse);
      expect(value.stored, isTrue);
      expect(value.providerReachable, isTrue);
      expect(value.toString(), isNot(contains('BLE-AA:BB')));

      api.values = [_evidence(providerReachable: false)];
      await controller.load();
      await controller.previewCalibration(controller.evidence.single);
      expect(api.previewCalls, 0);

      final gate = Completer<List<RoomPresenceEvidence>>();
      api.listGate = gate;
      final late = controller.load();
      current = false;
      gate.complete([_evidence(state: PresenceEvidenceState.uncertain)]);
      await late;
      expect(controller.evidence, isEmpty);
      expect(controller.state, RoomPresenceManagementState.stale);
    },
  );

  test(
    'calibration needs exact preview confirmation and verified readback',
    () async {
      var current = true;
      final api = _Api();
      final controller = RoomPresenceManagementController(
        api: api,
        authority: _authority,
        isCurrent: () => current,
        clock: () => DateTime.utc(2026, 9, 21, 12),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.previewCalibration(controller.evidence.single);
      expect(controller.pendingPreview, isNotNull);
      expect(api.confirmCalls, 0);

      final gate = Completer<PresenceCalibrationReceipt>();
      api.confirmGate = gate;
      final late = controller.confirmPending();
      current = false;
      final preview = controller.pendingPreview!;
      gate.complete(
        PresenceCalibrationReceipt(
          authority: _authority,
          requestId: preview.requestId,
          deviceId: preview.deviceId,
          deviceRevision: preview.deviceRevision,
          modelRevision: preview.modelRevision,
          roomId: preview.roomId,
          roomRevision: preview.roomRevision,
          policyRevision: preview.policyRevision,
          consentRevision: preview.consentRevision,
          previousCalibrationRevision: preview.previousCalibrationRevision,
          observedCalibrationRevision: preview.nextCalibrationRevision,
          status: PresenceCalibrationStatus.applied,
        ),
      );
      await late;
      expect(controller.state, RoomPresenceManagementState.stale);
      expect(api.readbackCalls, 0);

      current = true;
      api.confirmGate = null;
      await controller.load();
      await controller.previewCalibration(controller.evidence.single);
      await controller.confirmPending();
      expect(controller.state, RoomPresenceManagementState.verified);
      expect(controller.evidence.single.calibrationRevision, 'cal-r4');
      expect(api.confirmCalls, 2);
      expect(api.readbackCalls, 1);
    },
  );

  for (final language in ['en', 'tr']) {
    for (final size in [const Size(600, 900), const Size(1280, 900)]) {
      testWidgets(
        '$language presence management is accessible at ${size.width}px and 2x',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final semantics = tester.ensureSemantics();
          final api = _Api();
          final controller = RoomPresenceManagementController(
            api: api,
            authority: _authority,
            isCurrent: () => true,
            clock: () => DateTime.utc(2026, 9, 21, 12),
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
              home: RoomPresenceManagementScreen(controller: controller),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(2));
          final action = find.byKey(
            const ValueKey(
              'presence-calibrate-66666666666666666666666666666666',
            ),
          );
          expect(tester.getRect(action).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(action).flagsCollection.isButton, isTrue);
          expect(
            tester
                .getSemantics(
                  find.byKey(
                    const ValueKey(
                      'presence-state-66666666666666666666666666666666',
                    ),
                  ),
                )
                .label,
            contains(language == 'tr' ? 'Yalnız öneri' : 'Advisory only'),
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
          expect(tester.takeException(), isNull);

          final confirm = find.byKey(
            const ValueKey('presence-confirm-calibration'),
          );
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
