import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/camera_profiles/data/camera_profile_api.dart';
import 'package:larenor/features/camera_profiles/data/camera_profile_controller.dart';
import 'package:larenor/features/camera_profiles/domain/camera_profile_models.dart';
import 'package:larenor/features/camera_profiles/presentation/camera_profile_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const authority = CameraProfileAuthority(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: '33333333333333333333333333333333',
  sessionFamilyId: '44444444444444444444444444444444',
  profileId: '55555555555555555555555555555555',
  routeId: '43434343434343434343434343434343',
  homeRevision: 1,
  accountRevision: 2,
  profileRevision: 3,
  sessionRevision: 4,
  routeRevision: 5,
  canManage: true,
);

CameraProfileSnapshot snapshot() => CameraProfileSnapshot(
  authority: authority,
  reason: 'presence_home',
  microphoneDisabled: false,
  cameraHardwareDisabled: false,
  otherRecordersDisabled: false,
  cameras: const [
    CameraProfileCamera(
      id: '66666666666666666666666666666666',
      name: 'Front door',
      cameraRevision: 1,
      bindingRevision: 2,
      providerRevision: 3,
      stateRevision: 4,
      recordingSupported: true,
      detectionSupported: true,
      currentRecording: CameraSettingValue.enabled,
      currentDetection: CameraSettingValue.enabled,
      desiredRecording: CameraSettingValue.paused,
      desiredDetection: CameraSettingValue.disabled,
    ),
    CameraProfileCamera(
      id: '77777777777777777777777777777777',
      name: 'Living room',
      cameraRevision: 1,
      bindingRevision: 2,
      providerRevision: 3,
      stateRevision: 4,
      recordingSupported: false,
      detectionSupported: false,
      currentRecording: CameraSettingValue.enabled,
      currentDetection: CameraSettingValue.enabled,
      desiredRecording: CameraSettingValue.paused,
      desiredDetection: CameraSettingValue.disabled,
    ),
  ],
);

final class _Api implements CameraProfileApi {
  Completer<CameraProfileSnapshot>? loadGate;
  Completer<CameraApplyReceipt>? applyGate;
  var applyCalls = 0;
  var retired = false;

  @override
  Future<CameraProfileSnapshot> bootstrap() =>
      loadGate?.future ?? Future.value(snapshot());

  @override
  Future<CameraApplyReceipt> apply(CameraProfileSnapshot value) {
    applyCalls++;
    return applyGate?.future ??
        Future.value(
          const CameraApplyReceipt(
            requestId: '88888888888888888888888888888888',
            status: 'partial',
            results: [
              CameraApplyResult(
                cameraId: '66666666666666666666666666666666',
                state: CameraApplyState.applied,
                code: 'applied',
              ),
              CameraApplyResult(
                cameraId: '77777777777777777777777777777777',
                state: CameraApplyState.failed,
                code: 'provider_unsupported',
              ),
            ],
          ),
        );
  }

  @override
  void retire() => retired = true;
}

void main() {
  test('partial provider result remains visible per camera', () async {
    final api = _Api();
    final controller = CameraProfileController(api: api, isCurrent: () => true);
    addTearDown(controller.dispose);
    await controller.load();
    await controller.apply();
    expect(controller.state, CameraProfileViewState.partial);
    expect(controller.receipt!.results.map((item) => item.code), [
      'applied',
      'provider_unsupported',
    ]);
    expect(api.applyCalls, 1);
    expect(controller.snapshot!.makesNoHardwarePrivacyClaim, isTrue);
  });

  test('late apply is discarded when route authority retires', () async {
    var current = true;
    final api = _Api();
    final controller = CameraProfileController(
      api: api,
      isCurrent: () => current,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final gate = Completer<CameraApplyReceipt>();
    api.applyGate = gate;
    final pending = controller.apply();
    current = false;
    controller.setInteractive(false);
    gate.complete(
      const CameraApplyReceipt(
        requestId: '88888888888888888888888888888888',
        status: 'applied',
        results: [
          CameraApplyResult(
            cameraId: '66666666666666666666666666666666',
            state: CameraApplyState.applied,
            code: 'applied',
          ),
        ],
      ),
    );
    await pending;
    expect(controller.state, CameraProfileViewState.stale);
    expect(controller.snapshot, isNull);
    expect(api.retired, isTrue);
  });

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets(
        'tablet profile is accessible at $width ${locale.languageCode} 2x',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final controller = CameraProfileController(
            api: _Api(),
            isCurrent: () => true,
          );
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            CupertinoApp(
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: CameraProfileScreen(controller: controller),
            ),
          );
          await tester.pumpAndSettle();
          final l10n = AppLocalizations.of(
            tester.element(find.byType(CameraProfileScreen)),
          );
          expect(find.text(l10n.cameraProfilePrivacyBoundary), findsOneWidget);
          expect(find.text(l10n.cameraProfileUnsupported), findsOneWidget);
          final button = find.byKey(const ValueKey('camera-profile-apply'));
          expect(button, findsOneWidget);
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
