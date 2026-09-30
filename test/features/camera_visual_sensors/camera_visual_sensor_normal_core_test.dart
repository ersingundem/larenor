import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/camera_visual_sensors/data/camera_visual_sensor_api.dart';
import 'package:larenor/features/camera_visual_sensors/data/camera_visual_sensor_source_api.dart';
import 'package:larenor/features/camera_visual_sensors/domain/camera_visual_sensor_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_VISUAL_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);
  test(
    'Client → normal Core → TCP Frigate trained catalog and actual decoded WebP',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Visual gate',
      );
      expect(account.failure, isNull);
      final source = AccountVisualSourceApi(
        account: account,
        isCurrent: () => true,
      );
      addTearDown(source.retire);
      final catalog = await source.load();
      expect(catalog.decoderAvailable, isTrue);
      VisualSourceCamera? camera;
      List<VisualSourceModel> models = [];
      for (final candidate in catalog.cameras) {
        final actual = await source.models(
          candidate.id,
          catalog.sourceRevision,
        );
        if (actual.isNotEmpty) {
          camera = candidate;
          models = actual;
          break;
        }
      }
      expect(camera, isNotNull);
      expect(models.single.name, 'door');
      final saved = await source.save(
        ruleId: '4' * 32,
        revision: 0,
        cameraId: camera!.id,
        model: models.single.name,
        label: 'open',
        confidenceBps: 9000,
        holdMs: 1000,
        clearMs: 1000,
        retentionMs: 30000,
      );
      expect(saved.state, VisualSensorState.unknown);
      await account.withSession((api, session) async {
        final gateway = CameraVisualSensorApi(
          api,
          session,
          isCurrent: () => true,
        );
        addTearDown(gateway.retire);
        await gateway.load();
        final actual = await gateway.load();
        expect(actual.sensors.single.state, VisualSensorState.on);
        expect(
          actual.sensors.single.evidenceDigest,
          matches(RegExp(r'^[0-9a-f]{64}$')),
        );
        expect(actual.sensors.single.automationEligible, isTrue);
        expect(actual.capability.architecture, VisualArchitecture.other);
        expect(actual.capability.trainingSupported, isFalse);
      });
    },
    skip: url == null ? 'Requires explicit isolated normal Core runner' : false,
  );
}
