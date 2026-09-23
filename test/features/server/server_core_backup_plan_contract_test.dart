import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/core_backups/domain/server_core_backup_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

Map<String, Object?> blockedPlan(List<String> blockers) => {
  'status': 'blocked',
  'blockers': blockers,
  'manifest': null,
};

void main() {
  test('plan parser rejects duplicate blockers', () {
    expect(
      () => CoreBackupPlan.fromJson(
        blockedPlan(['active_plugin_job', 'active_plugin_job']),
      ),
      throwsA(isA<LarenorServerException>()),
    );
  });

  test('plan parser rejects blockers outside service order', () {
    expect(
      () => CoreBackupPlan.fromJson(
        blockedPlan(['active_plugin_job', 'active_bounded_transfer']),
      ),
      throwsA(isA<LarenorServerException>()),
    );
  });

  test('plan parser requires an exclusive quiescence blocker', () {
    for (final blockers in <List<String>>[
      ['active_bounded_transfer', 'component_quiescence_timeout'],
      ['component_quiescence_timeout', 'component_quiescence_unavailable'],
    ]) {
      expect(
        () => CoreBackupPlan.fromJson(blockedPlan(blockers)),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });

  test('plan parser accepts canonical service blocker outputs', () {
    for (final blockers in <List<String>>[
      ['active_bounded_transfer', 'active_plugin_job'],
      ['active_plugin_job', 'active_media_installation'],
      ['component_quiescence_timeout'],
      ['component_quiescence_unavailable'],
    ]) {
      expect(CoreBackupPlan.fromJson(blockedPlan(blockers)).blockers, blockers);
    }
  });
}
