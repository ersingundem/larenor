import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/core_backups/domain/server_core_backup_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  group('Core backup component quiescence blockers', () {
    for (final blocker in const {
      'component_quiescence_timeout',
      'component_quiescence_unavailable',
    }) {
      test('accepts $blocker as a bounded blocked plan', () {
        final plan = CoreBackupPlan.fromJson({
          'status': 'blocked',
          'blockers': [blocker],
          'manifest': null,
        });

        expect(plan.ready, isFalse);
        expect(plan.blockers, [blocker]);
      });
    }

    test('continues to reject unknown blocker codes', () {
      expect(
        () => CoreBackupPlan.fromJson({
          'status': 'blocked',
          'blockers': ['synthetic_unbounded_blocker'],
          'manifest': null,
        }),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });

    test('preserves the Server maximum of eleven blocker codes', () {
      expect(
        () => CoreBackupPlan.fromJson({
          'status': 'blocked',
          'blockers': CoreBackupPlan.allowedBlockers.take(12).toList(),
          'manifest': null,
        }),
        throwsA(isA<LarenorServerException>()),
      );
    });
  });
}
