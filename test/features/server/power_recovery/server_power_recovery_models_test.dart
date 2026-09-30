import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/power_recovery/domain/server_power_recovery_models.dart';

void main() {
  test('versioned Proxmox provider reference round trips exact authority', () {
    final target = PowerRecoveryTarget.fromJson({
      'targetId': '11111111111111111111111111111111',
      'label': 'Lab VM',
      'kind': 'proxmoxGuest',
      'shutdownOrder': 1,
      'startOnRestore': true,
      'timeoutSeconds': 30,
      'providerRef': {
        'contractVersion': 1,
        'provider': 'proxmox',
        'actorId': '22222222222222222222222222222222',
        'actorRevision': 3,
        'coreId': '33333333333333333333333333333333',
        'homeId': '44444444444444444444444444444444',
        'resourceId': '55555555555555555555555555555555',
        'resourceRevision': 5,
        'aclRevision': 6,
        'bindingId': 'binding_1',
        'bindingRevision': 7,
        'serviceId': 'service_1',
        'serviceRevision': 8,
        'egressRevision': 9,
        'installationId': 'service_1',
        'node': 'node-a',
        'guestKind': 'qemu',
        'guestId': 101,
        'statusRevision': 10,
      },
    });

    expect(target.providerRef?.resourceId, '55555555555555555555555555555555');
    expect(target.providerRef?.egressRevision, 9);
    expect(target.toJson()['providerRef'], target.providerRef?.toJson());
  });

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
