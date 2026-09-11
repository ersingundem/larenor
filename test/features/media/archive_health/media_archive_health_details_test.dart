import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/archive_health/data/media_archive_health_controller.dart';
import 'package:larenor/features/media/archive_health/domain/media_archive_health.dart';
import 'package:larenor/features/media/archive_health/presentation/media_archive_health_card.dart';
import 'package:larenor/features/media/archive_health/presentation/media_archive_health_detail_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

Map<String, Object?> detailArchiveJson({String state = 'attention'}) => {
  'installationId': '11111111111111111111111111111111',
  'installationRevision': 12,
  'snapshotRevision': 4,
  'state': state,
  'sourceStates': {
    'jellyfin': state == 'incomplete' ? 'stale' : 'verified',
    'sonarr': 'verified',
    'radarr': 'verified',
    'qbittorrent': 'verified',
  },
  'sourceRevisions': {
    'jellyfin': 7,
    'sonarr': 7,
    'radarr': 7,
    'qbittorrent': 7,
  },
  'counts': {
    'missing': 1,
    'broken': 1,
    'failedDownloads': 1,
    'savingCandidates': 1,
    'potentialSavingBytes': 4000000000,
  },
  'issues': [
    {
      'code': 'corrupt_media',
      'severity': 'critical',
      'source': 'jellyfin',
      'sourceItemId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'mediaKey': 'episode:tvdb:101:1:2',
      'title': 'Pilot',
      'observedBytes': 2000,
    },
    {
      'code': 'missing_media',
      'severity': 'warning',
      'source': 'sonarr',
      'sourceItemId': 'episode:tvdb:101:1:3',
      'mediaKey': 'episode:tvdb:101:1:3',
      'title': 'Second episode',
      'observedBytes': 0,
    },
  ],
  'suggestions': [
    {
      'code': 'review_retained_download',
      'torrentId': 'cccccccccccccccccccccccccccccccccccccccc',
      'mediaKey': 'movie:tmdb:603',
      'title': 'The Matrix download',
      'potentialBytes': 4000000000,
      'evidence': [
        'download_complete',
        'import_verified',
        'retention_policy_satisfied',
      ],
      'cleanupAvailable': false,
    },
  ],
  'cleanupAvailable': false,
  'generatedAt': 1788609610,
};

Widget app(Widget child, {double scale = 1}) => CupertinoApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, nested) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: nested!,
  ),
  home: CupertinoPageScaffold(child: child),
);

void main() {
  test('strict read model retains bounded issue and saving evidence', () {
    final snapshot = MediaArchiveHealthSnapshot.fromJson(detailArchiveJson());
    expect(snapshot.issues.first.code, MediaArchiveIssueCode.corruptMedia);
    expect(snapshot.issues.last.severity, MediaArchiveIssueSeverity.warning);
    expect(snapshot.suggestions.single.potentialBytes, 4000000000);
    expect(snapshot.suggestions.single.evidence, [
      MediaArchiveSavingEvidence.downloadComplete,
      MediaArchiveSavingEvidence.importVerified,
      MediaArchiveSavingEvidence.retentionPolicySatisfied,
    ]);
    expect(snapshot.cleanupAvailable, isFalse);
  });

  testWidgets('card opens read-only evidence with keyboard', (tester) async {
    final snapshot = MediaArchiveHealthSnapshot.fromJson(detailArchiveJson());
    final controller = MediaArchiveHealthController(
      read: () async => snapshot,
      authorized: () => true,
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    await tester.pumpWidget(
      app(MediaArchiveHealthCard(controller: controller)),
    );
    final details = find.byKey(const ValueKey('media-archive-details'));
    expect(details, findsOneWidget);
    expect(tester.getSize(details).height, greaterThanOrEqualTo(48));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(MediaArchiveHealthDetailScreen), findsOneWidget);
    expect(find.text('The Matrix download'), findsOneWidget);
    expect(find.text('Pilot'), findsOneWidget);
  });

  testWidgets(
    'detail is responsive at 600 and 1280 with 2x text and TalkBack',
    (tester) async {
      final snapshot = MediaArchiveHealthSnapshot.fromJson(detailArchiveJson());
      for (final width in [600.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          app(MediaArchiveHealthDetailScreen(snapshot: snapshot), scale: 2),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Pilot'),
          250,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel(RegExp(r'Pilot.*Critical')),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.text('The Matrix download'),
          300,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel(RegExp(r'The Matrix download.*4\.0 GB')),
          findsOneWidget,
        );
        expect(
          find.textContaining(RegExp(r'clean|delete', caseSensitive: false)),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        semantics.dispose();
      }
      addTearDown(tester.view.reset);
    },
  );

  testWidgets('partial detail keeps stale source visible', (tester) async {
    final snapshot = MediaArchiveHealthSnapshot.fromJson(
      detailArchiveJson(state: 'incomplete'),
    );
    await tester.pumpWidget(
      app(MediaArchiveHealthDetailScreen(snapshot: snapshot)),
    );
    expect(find.text('Partial evidence'), findsOneWidget);
    expect(find.textContaining('Jellyfin · Stale'), findsOneWidget);
  });
}
