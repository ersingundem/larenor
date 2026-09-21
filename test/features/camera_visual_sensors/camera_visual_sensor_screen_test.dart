import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/camera_visual_sensors/data/camera_visual_sensor_controller.dart';
import 'package:larenor/features/camera_visual_sensors/domain/camera_visual_sensor_models.dart';
import 'package:larenor/features/camera_visual_sensors/presentation/camera_visual_sensor_screen.dart';

final class _Gateway implements CameraVisualSensorGateway {
  int loads = 0;
  @override
  Future<CameraVisualSensorSummary> load() async {
    loads++;
    return CameraVisualSensorSummary(
      coreId: 'a' * 32,
      homeId: 'b' * 32,
      capability: const VisualEngineCapability(
        architecture: VisualArchitecture.arm64,
        avx: VisualCpuSupport.notApplicable,
        avx2: VisualCpuSupport.notApplicable,
        arm64: true,
        reason: 'arm64_unverified',
      ),
      sensors: [
        CameraVisualSensor(
          ruleId: 'c' * 32,
          ruleRevision: 1,
          cameraId: 'd' * 32,
          pipelineId: 'e' * 32,
          pipelineRevision: 2,
          modelId: 'f' * 32,
          modelRevision: 3,
          label: 'Front door person',
        ),
        CameraVisualSensor(
          ruleId: '1' * 32,
          ruleRevision: 1,
          cameraId: '2' * 32,
          pipelineId: '3' * 32,
          pipelineRevision: 2,
          modelId: '4' * 32,
          modelRevision: 3,
          label: 'Garage vehicle',
        ),
      ],
    );
  }

  @override
  void retire() {}
}

Future<_Gateway> _mount(
  WidgetTester tester,
  CameraVisualSensorStrings strings,
  double width,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1200);
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final gateway = _Gateway();
  await tester.pumpWidget(
    CupertinoApp(
      home: CameraVisualSensorScreen(
        controller: CameraVisualSensorController(
          gateway: gateway,
          isCurrent: () => true,
          coreId: 'a' * 32,
          homeId: 'b' * 32,
        ),
        strings: strings,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return gateway;
}

void main() {
  for (final value in [
    (CameraVisualSensorStrings.en, 'en'),
    (CameraVisualSensorStrings.tr, 'tr'),
  ]) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('${value.$2} $width at 2x is readable and adaptive', (
        tester,
      ) async {
        await _mount(tester, value.$1, width);
        expect(find.text(value.$1.title), findsOneWidget);
        expect(find.text(value.$1.detectorUnavailable), findsOneWidget);
        expect(find.text(value.$1.unknown), findsNWidgets(2));
        expect(find.text(value.$1.notAuthority), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        final first = tester.getTopLeft(
          find.byKey(ValueKey('visual-sensor-${'c' * 32}')),
        );
        final second = tester.getTopLeft(
          find.byKey(ValueKey('visual-sensor-${'1' * 32}')),
        );
        if (width >= 1000) {
          expect(second.dx, greaterThan(first.dx));
          expect(second.dy, first.dy);
        } else {
          expect(second.dx, first.dx);
          expect(second.dy, greaterThan(first.dy));
        }
      });
    }
  }

  testWidgets('TalkBack and keyboard expose the bounded refresh action', (
    tester,
  ) async {
    final gateway = await _mount(tester, CameraVisualSensorStrings.en, 1280);
    final semantics = tester.ensureSemantics();
    final refresh = find.byKey(const ValueKey('visual-sensor-refresh'));
    expect(tester.getSize(refresh).height, greaterThanOrEqualTo(48));
    expect(
      tester.getSemantics(refresh).label,
      CameraVisualSensorStrings.en.refresh,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(gateway.loads, 2);
    semantics.dispose();
  });
}
