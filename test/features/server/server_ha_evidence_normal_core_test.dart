import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/evidence_diagnostics/data/server_evidence_diagnostic_api.dart';
import 'package:larenor/features/server/habit_anomalies/data/server_habit_anomaly_api.dart';

void main() {
  final coreUrl = Platform.environment['LARENOR_HA_EVIDENCE_CORE_URL'];
  final token = Platform.environment['LARENOR_HA_EVIDENCE_TOKEN'];
  final coreId = Platform.environment['LARENOR_HA_EVIDENCE_CORE_ID'];
  final homeId = Platform.environment['LARENOR_HA_EVIDENCE_HOME_ID'];

  setUpAll(() => HttpOverrides.global = null);
  test(
    'actual Client → normal Core → HA registry/history evidence stays bounded',
    () async {
      final transport = LarenorServerApi(endpoint: ServerEndpoint(coreUrl!));
      addTearDown(transport.close);
      final context = ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': coreId,
        'homeId': homeId,
      });
      final habit = await ServerHabitAnomalyApi(
        transport,
        token!,
        context,
      ).observeServices('normal-core-habit-key-0001');
      expect(habit.sampleCount, greaterThanOrEqualTo(13));
      expect(habit.current.source, 'real');
      expect(habit.current.evidence?.provider, 'home_assistant_history');
      expect(habit.current.evidence?.entityId, 'binary_sensor.hall_motion');

      final diagnostics = ServerEvidenceDiagnosticApi(
        transport,
        token,
        context,
      );
      final diagnosis = await diagnostics.diagnoseServices(
        'normal-core-diagnosis-key-0001',
      );
      expect(diagnosis.certainty, 'limited');
      expect(diagnosis.sources.single.provenance, 'home_assistant_history');
      expect(diagnosis.sources.single.entityId, 'binary_sensor.hall_motion');
      expect(diagnosis.unknownCodes, contains('source_state_unknown'));
      final preview = await diagnostics.preview(
        diagnosis,
        'normal-core-preview-key-0001',
      );
      expect(preview.stepCodes, contains('collect_fresh_evidence'));
    },
    skip: coreUrl == null || token == null || coreId == null || homeId == null
        ? 'Requires explicit isolated normal Core runner'
        : false,
  );
}
