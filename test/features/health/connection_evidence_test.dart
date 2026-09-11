import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/health/data/connection_evidence.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/connection_evidence_status.dart';

final _now = DateTime.utc(2026, 9, 11, 12);

Future<void> _mount(
  WidgetTester tester,
  ConnectionEvidence evidence, {
  String locale = 'en',
  double scale = 1,
  double width = 600,
}) async {
  tester.view.physicalSize = Size(width, 500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: CupertinoPageScaffold(
        child: Center(
          child: SizedBox(
            width: 360,
            child: ConnectionEvidenceStatus(evidence: evidence),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('normalizes service evidence without promoting transport contact', () {
    expect(
      ConnectionEvidence.fromHealth(
        IntegrationHealth(lastContact: _now, lastSuccessfulRead: _now),
        HealthStatus.healthy,
      ).stage,
      ConnectionEvidenceStage.none,
      reason: 'unsaved targets never inherit contradictory remote evidence',
    );
    expect(
      ConnectionEvidence.fromHealth(
        const IntegrationHealth(configured: true),
        HealthStatus.configured,
      ).stage,
      ConnectionEvidenceStage.saved,
    );
    expect(
      ConnectionEvidence.fromHealth(
        IntegrationHealth(configured: true, lastContact: _now),
        HealthStatus.reachable,
      ).stage,
      ConnectionEvidenceStage.reachable,
    );
    expect(
      ConnectionEvidence.fromHealth(
        IntegrationHealth(configured: true, lastContact: _now),
        HealthStatus.healthy,
      ).stage,
      ConnectionEvidenceStage.reachable,
      reason: 'a malformed healthy status without a verified read fails closed',
    );
    expect(
      ConnectionEvidence.fromHealth(
        IntegrationHealth(
          configured: true,
          lastContact: _now,
          lastSuccessfulRead: _now,
        ),
        HealthStatus.healthy,
      ).stage,
      ConnectionEvidenceStage.verified,
    );
  });

  testWidgets('saved reachable verified stale and offline remain distinct', (
    tester,
  ) async {
    await _mount(tester, const ConnectionEvidence.saved());
    expect(find.text('Saved connection'), findsOneWidget);
    expect(find.text('Not yet verified'), findsOneWidget);

    await _mount(tester, const ConnectionEvidence.reachable());
    expect(
      find.text('Server responded; data not yet verified'),
      findsOneWidget,
    );
    expect(find.text('Data read successfully'), findsNothing);

    await _mount(tester, ConnectionEvidence.verified(_now));
    expect(find.text('Data read successfully'), findsOneWidget);

    await _mount(tester, ConnectionEvidence.stale(_now));
    expect(find.text('Last read is out of date'), findsOneWidget);

    await _mount(
      tester,
      ConnectionEvidence.unavailable(
        stage: ConnectionEvidenceStage.verified,
        lastVerifiedAt: _now,
      ),
    );
    expect(find.text('Unable to reach service'), findsOneWidget);
    expect(find.textContaining('Last successful read:'), findsOneWidget);
  });

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'status fits tablet cards at 2x and exposes one live label ($locale $width)',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await _mount(
              tester,
              ConnectionEvidence.stale(_now),
              locale: locale,
              scale: 2,
              width: width,
            );
            expect(tester.takeException(), isNull);
            final node = tester.getSemantics(
              find.byKey(const ValueKey('connection-evidence-status')),
            );
            expect(node.flagsCollection.isLiveRegion, isTrue);
            expect(
              node.label,
              contains(locale == 'tr' ? 'güncelliğini yitirdi' : 'out of date'),
            );
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}
