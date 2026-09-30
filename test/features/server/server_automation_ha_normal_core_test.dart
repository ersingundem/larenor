import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/automation_trials/data/server_automation_trial_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  final coreUrl = Platform.environment['LARENOR_AUTOMATION_CORE_URL'];
  final token = Platform.environment['LARENOR_AUTOMATION_TOKEN'];
  final coreId = Platform.environment['LARENOR_AUTOMATION_CORE_ID'];
  final homeId = Platform.environment['LARENOR_AUTOMATION_HOME_ID'];

  setUpAll(() => HttpOverrides.global = null);
  test(
    'actual Client → normal Core → HA trace WS publishes bounded real evidence',
    () async {
      final api = LarenorServerApi(endpoint: ServerEndpoint(coreUrl!));
      addTearDown(api.close);
      final context = ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': coreId,
        'homeId': homeId,
      });
      final trials = ServerAutomationTrialApi(api, token!, context);
      final trial = await trials.snapshot();
      expect(trial, isNotNull);
      final observed = await trials.evaluate(trial!, 'real');
      expect(observed.eventCount, 1);
      expect(observed.events.single.source, 'real');
      expect(observed.events.single.evidence?.provider, 'home_assistant_trace');
      expect(observed.events.single.evidence?.runId, 'a' * 32);
      final replay = await trials.replay(observed);
      expect(replay.status, 'complete');
      expect(replay.availableEventCount, 1);
    },
    skip: coreUrl == null || token == null || coreId == null || homeId == null
        ? 'Requires explicit isolated normal Core runner'
        : false,
  );
}
