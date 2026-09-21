import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/camera_search/data/camera_search_controller.dart';
import 'package:larenor/features/camera_search/domain/camera_search_models.dart';
import 'package:larenor/features/camera_search/presentation/camera_search_screen.dart';

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
    for (var index = 0; index < 2; index++)
      CameraSearchMatch(
        start: DateTime.utc(2026, 9, 5, 12, index),
        end: DateTime.utc(2026, 9, 5, 12, index + 1),
        summary: index == 0
            ? 'A parcel was left by the door'
            : 'A person walked past the garden',
        matchedTerms: const ['door'],
        evidence: CameraSearchEvidence(
          coreId: 'a' * 32,
          homeId: 'b' * 32,
          cameraId: 'd' * 32,
          clipId: '${index + 1}' * 32,
          eventId: '${index + 3}' * 32,
          captureRevision: 4,
          indexRevision: 7,
          capturedAt: DateTime.utc(2026, 9, 5, 12, index, 10),
        ),
      ),
  ],
);

final class _Gateway implements CameraSearchGateway {
  int calls = 0;
  @override
  Future<CameraSearchPage> search({
    required String query,
    required CameraSearchFilter filter,
    String? cursor,
  }) async {
    calls++;
    return page();
  }

  @override
  void retire() {}
}

Future<_Gateway> _pump(
  WidgetTester tester, {
  required double width,
  required CameraSearchStrings strings,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final gateway = _Gateway();
  await tester.pumpWidget(
    CupertinoApp(
      home: CameraSearchScreen(
        controller: CameraSearchController(
          gateway: gateway,
          isCurrent: () => true,
        ),
        strings: strings,
        filter: filter(),
        cameraNames: {'d' * 32: strings.cameraName},
      ),
    ),
  );
  await tester.pump();
  return gateway;
}

void main() {
  for (final entry in [
    (CameraSearchStrings.en, 'en'),
    (CameraSearchStrings.tr, 'tr'),
  ]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets('${entry.$2} $width at 2x remains adaptive', (tester) async {
        await _pump(tester, width: width, strings: entry.$1);
        await tester.enterText(
          find.byKey(const ValueKey('camera-search-field')),
          'parcel at door',
        );
        await tester.tap(find.byKey(const ValueKey('camera-search-submit')));
        await tester.pumpAndSettle();
        expect(find.text(entry.$1.localOnly), findsOneWidget);
        expect(tester.takeException(), isNull);
        final first = tester.getTopLeft(
          find.byKey(const ValueKey('camera-result-1')),
        );
        final second = tester.getTopLeft(
          find.byKey(const ValueKey('camera-result-2')),
        );
        if (width >= 1000) {
          expect(second.dx, greaterThan(first.dx));
          expect(second.dy, first.dy);
        } else {
          expect(second.dx, first.dx);
          expect(second.dy, greaterThan(first.dy));
        }
        expect(
          tester
              .getSize(find.byKey(const ValueKey('camera-search-submit')))
              .height,
          greaterThanOrEqualTo(48),
        );
      });
    }
  }

  testWidgets('keyboard and TalkBack submit a read-only search', (
    tester,
  ) async {
    final gateway = await _pump(
      tester,
      width: 1280,
      strings: CameraSearchStrings.en,
    );
    final semantics = tester.ensureSemantics();
    await tester.enterText(
      find.byKey(const ValueKey('camera-search-field')),
      'parcel at door',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(gateway.calls, 1);
    expect(find.text('A parcel was left by the door'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('camera-search-submit')))
          .label,
      CameraSearchStrings.en.search,
    );
    expect(find.textContaining('https://'), findsNothing);
    semantics.dispose();
  });
}
