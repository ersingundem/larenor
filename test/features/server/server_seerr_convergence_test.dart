import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_preparations/domain/server_seerr_convergence.dart';

import 'server_media_preparations_test_support.dart';

Map<String, Object?> record() => {
  'id': '1' * 32,
  'requestId': '2' * 32,
  'installationId': '3' * 32,
  'sourceBootstrapId': '4' * 32,
  'sourceBootstrapRevision': 3,
  'serviceId': 'seerr',
  'revision': 4,
  'state': 'succeeded',
  'phase': 'complete',
  'errorCode': null,
  'installAvailable': false,
  'convergencePhase': 'verified',
  'arrWired': true,
  'initialized': true,
  'createdAt': '2026-09-05T12:00:00.000Z',
  'updatedAt': '2026-09-05T12:00:00.000Z',
};

void main() {
  test('accepts only coherent verified convergence evidence', () {
    final value = ServerSeerrConvergence.fromJson(record());
    expect(value.state, 'succeeded');
    expect(value.arrWired, isTrue);
    expect(value.initialized, isTrue);
    expect(value.needsRecovery, isFalse);
  });

  test('accepts the tablet HTTP fixture', () {
    expect(
      ServerSeerrConvergence.fromJson(
        seerrConvergenceJson(mediaPreparationJson()),
      ).phase,
      'verified',
    );
  });

  test('rejects a successful label without initialization proof', () {
    expect(
      () => ServerSeerrConvergence.fromJson(record()..['initialized'] = false),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });
}
