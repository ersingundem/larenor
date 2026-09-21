import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/camera_search/data/camera_search_controller.dart';
import 'package:larenor/features/camera_search/domain/camera_search_models.dart';

CameraSearchFilter filter() => CameraSearchFilter(
  expectedIndexRevision: 7,
  start: DateTime.utc(2026, 9, 5, 12),
  end: DateTime.utc(2026, 9, 5, 13),
  cameraIds: ['d' * 32],
);

CameraSearchPage page() => CameraSearchPage(
  indexRevision: 7,
  mode: CameraSearchMode.localMetadata,
  status: CameraSearchStatus.degraded,
  degradedReason: CameraSearchDegradedReason.semanticProviderUnavailable,
  results: [
    CameraSearchMatch(
      start: DateTime.utc(2026, 9, 5, 12),
      end: DateTime.utc(2026, 9, 5, 12, 1),
      summary: 'A parcel was left by the door',
      matchedTerms: const ['parcel', 'door'],
      evidence: CameraSearchEvidence(
        coreId: 'a' * 32,
        homeId: 'b' * 32,
        cameraId: 'd' * 32,
        clipId: 'e' * 32,
        eventId: 'f' * 32,
        captureRevision: 4,
        indexRevision: 7,
        capturedAt: DateTime.utc(2026, 9, 5, 12, 0, 10),
      ),
    ),
  ],
);

final class _Gateway implements CameraSearchGateway {
  Completer<CameraSearchPage>? delayed;
  int calls = 0;
  @override
  Future<CameraSearchPage> search({
    required String query,
    required CameraSearchFilter filter,
    String? cursor,
  }) {
    calls++;
    return delayed?.future ?? Future.value(page());
  }

  @override
  void retire() {}
}

void main() {
  test(
    'exact current route publishes immutable privacy-scoped results',
    () async {
      final gateway = _Gateway();
      final controller = CameraSearchController(
        gateway: gateway,
        isCurrent: () => true,
      );
      await controller.search('parcel at door', filter());
      expect(controller.results, hasLength(1));
      expect(controller.results.single.summary, contains('parcel'));
      expect(controller.failure, isNull);
      expect(gateway.calls, 1);
    },
  );

  test('late response after route authority changes is discarded', () async {
    var current = true;
    final gateway = _Gateway()..delayed = Completer<CameraSearchPage>();
    final controller = CameraSearchController(
      gateway: gateway,
      isCurrent: () => current,
    );
    final pending = controller.search('parcel at door', filter());
    current = false;
    gateway.delayed!.complete(page());
    await pending;
    expect(controller.results, isEmpty);
    expect(controller.failure, CameraSearchFailure.staleAuthority);
  });
}
