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
    expect(value.publicPhase, 'complete');
    expect(value.sourceBootstrapRevision, 3);
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

  test('accepts coherent terminal cancellation without recovery action', () {
    final value = ServerSeerrConvergence.fromJson(
      record()
        ..['state'] = 'cancelled'
        ..['convergencePhase'] = 'initialize'
        ..['initialized'] = false,
    );
    expect(value.cancelled, isTrue);
    expect(value.needsRecovery, isFalse);
  });

  test('rejects forged or incoherent public convergence evidence', () {
    final malformed = <Map<String, Object?>>[
      record()..['phase'] = 'private_worker',
      record()..['requestId'] = 'wrong',
      record()..['sourceBootstrapRevision'] = 0,
      record()..['revision'] = true,
      record()..['createdAt'] = '2026-09-05 12:00:00Z',
      record()
        ..['createdAt'] = '2026-09-05T12:00:01.000Z'
        ..['updatedAt'] = '2026-09-05T12:00:00.000Z',
      record()..['errorCode'] = 'seerr_bootstrap_initialization_failed',
      record()
        ..['state'] = 'needs_attention'
        ..['errorCode'] = null,
      record()
        ..['state'] = 'cancelled'
        ..['errorCode'] = 'seerr_bootstrap_timeout',
      record()
        ..['state'] = 'running'
        ..['phase'] = 'complete'
        ..['convergencePhase'] = 'bootstrap'
        ..['arrWired'] = false
        ..['initialized'] = false,
      record()
        ..['state'] = 'needs_attention'
        ..['errorCode'] = 'unknown_error',
      record()
        ..['state'] = 'needs_attention'
        ..['errorCode'] = 'seerr_bootstrap_initialization_failed'
        ..['convergencePhase'] = 'arr_wiring',
    ];

    for (final value in malformed) {
      expect(
        () => ServerSeerrConvergence.fromJson(value),
        throwsA(isA<LarenorServerException>()),
        reason: value.toString(),
      );
    }
  });
}
