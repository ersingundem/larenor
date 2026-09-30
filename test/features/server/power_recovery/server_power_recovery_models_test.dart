import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/power_recovery/domain/server_power_recovery_models.dart';

void main() {
  test(
    'uncertain durable effect receipt is parsed without permitting replay',
    () {
      final step = PowerRecoveryStep.fromJson({
        'stepId': '11111111111111111111111111111111',
        'sequence': 4,
        'action': 'shutdownTarget',
        'targetId': '22222222222222222222222222222222',
        'targetKind': 'proxmoxGuest',
        'state': 'uncertain',
        'resultCode': 'reconciliation_required',
        'createdAt': 1,
        'updatedAt': 2,
      });

      expect(step.state, PowerStepState.uncertain);
      expect(step.resultCode, 'reconciliation_required');
    },
  );
}
