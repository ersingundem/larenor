import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/camera_visual_sensors/data/camera_visual_sensor_source_api.dart';
import 'package:larenor/features/camera_visual_sensors/domain/camera_visual_sensor_models.dart';
import 'package:larenor/features/camera_visual_sensors/presentation/camera_visual_sensor_source_editor.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import '../server/server_admin_test_support.dart';

final cameraId = 'e' * 32, ruleId = 'd' * 32;
Map<String, Object?> _catalog() => {
  'schemaVersion': 1,
  'cameraSourceRevision': 3,
  'cameras': [
    {'id': cameraId, 'name': 'Front door'},
  ],
  'bindings': <Object?>[],
  'trainingRequirement':
      'Frigate 0.17: AVX+AVX2; configure and train in Frigate',
  'frameDecoderAvailable': true,
};
Map<String, Object?> _models() => {
  'schemaVersion': 1,
  'cameraId': cameraId,
  'cameraSourceRevision': 3,
  'models': [
    {
      'name': 'door',
      'revision': 4503599627370496,
      'labels': ['open', 'closed'],
    },
  ],
};

void main() {
  test(
    'actual source choices are bounded and reject mismatched source revisions',
    () async {
      final fixture = AdminFixture();
      addTearDown(fixture.account.dispose);
      await fixture.account.initialize();
      var mismatch = false;
      fixture.respond = (request) async => fixture.json(
        request.url.path.endsWith('/sources')
            ? _catalog()
            : {..._models(), if (mismatch) 'cameraSourceRevision': 4},
      );
      final api = AccountVisualSourceApi(
        account: fixture.account,
        isCurrent: () => true,
      );
      addTearDown(api.retire);
      final catalog = await api.load();
      expect(catalog.cameras.single.name, 'Front door');
      expect((await api.models(cameraId, 3)).single.revision, 4503599627370496);
      mismatch = true;
      await expectLater(
        api.models(cameraId, 3),
        throwsA(isA<LarenorServerException>()),
      );
    },
  );
  test(
    'late response after route retirement releases no private source result',
    () async {
      final fixture = AdminFixture();
      addTearDown(fixture.account.dispose);
      await fixture.account.initialize();
      final response = Completer<http.Response>();
      fixture.respond = (_) => response.future;
      final api = AccountVisualSourceApi(
        account: fixture.account,
        isCurrent: () => true,
      );
      final result = api.load();
      api.retire();
      response.complete(fixture.json(_catalog()));
      await expectLater(result, throwsA(isA<LarenorServerException>()));
    },
  );
  testWidgets(
    'inline setup chooses genuine model label and sends exact bounded policy',
    (tester) async {
      final gateway = _Gateway();
      var closed = false;
      await tester.pumpWidget(
        CupertinoApp(
          home: CupertinoPageScaffold(
            child: SafeArea(
              child: SingleChildScrollView(
                child: CameraVisualSourceEditor(
                  gateway: gateway,
                  isCurrent: () => true,
                  onClose: () => closed = true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Front door'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('door'));
      await tester.tap(find.text('door'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('open'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('visual-source-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(gateway.saved, {
        'cameraId': cameraId,
        'model': 'door',
        'label': 'open',
        'confidence': 9000,
        'hold': 2000,
        'clear': 2000,
        'retention': 30000,
      });
      expect(closed, isTrue);
    },
  );
  testWidgets('missing actual trained model cannot enable Save', (
    tester,
  ) async {
    final gateway = _Gateway()..empty = true;
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: SingleChildScrollView(
            child: CameraVisualSourceEditor(
              gateway: gateway,
              isCurrent: () => true,
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Front door'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No trained single-camera'), findsOneWidget);
    expect(
      tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('visual-source-save')),
          )
          .onPressed,
      isNull,
    );
    expect(gateway.saved, isNull);
  });
}

final class _Gateway implements VisualSourceGateway {
  bool empty = false;
  Map<String, Object?>? saved;
  @override
  Future<VisualSourceCatalog> load() async => VisualSourceCatalog(
    3,
    [VisualSourceCamera(cameraId, 'Front door')],
    const [],
    true,
  );
  @override
  Future<List<VisualSourceModel>> models(String id, int revision) async => empty
      ? []
      : [
          const VisualSourceModel('door', 4, ['open', 'closed']),
        ];
  @override
  Future<CameraVisualSensor> save({
    required String ruleId,
    required int revision,
    required String cameraId,
    required String model,
    required String label,
    required int confidenceBps,
    required int holdMs,
    required int clearMs,
    required int retentionMs,
  }) async {
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(ruleId), isTrue);
    expect(revision, 0);
    saved = {
      'cameraId': cameraId,
      'model': model,
      'label': label,
      'confidence': confidenceBps,
      'hold': holdMs,
      'clear': clearMs,
      'retention': retentionMs,
    };
    return CameraVisualSensor(
      ruleId: ruleId,
      ruleRevision: 1,
      cameraId: cameraId,
      pipelineId: '1' * 32,
      pipelineRevision: 1,
      modelId: '2' * 32,
      modelRevision: 4,
      label: label,
    );
  }

  @override
  void retire() {}
}
