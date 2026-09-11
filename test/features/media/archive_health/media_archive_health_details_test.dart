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
  'savingsPlan': {
    'state': state == 'incomplete' ? 'partial' : 'ready',
    'laneStates': {
      'duplicate': state == 'incomplete' ? 'stale' : 'verified',
      'transcode': state == 'incomplete' ? 'stale' : 'verified',
      'retention': state == 'incomplete' ? 'stale' : 'verified',
    },
    'candidates': state == 'incomplete'
        ? <Object?>[]
        : [
            {
              'kind': 'duplicate',
              'source': 'jellyfin',
              'title': 'The Matrix duplicate',
              'potentialBytes': 4000000000,
              'evidence': [
                'same_media_identity',
                'multiple_playable_files',
                'largest_copy_excluded',
              ],
              'actionAvailable': false,
            },
            {
              'kind': 'transcode',
              'source': 'jellyfin',
              'title': 'Home video',
              'potentialBytes': 2000000000,
              'evidence': [
                'source_profile_verified',
                'target_playback_verified',
                'bounded_size_estimate',
              ],
              'actionAvailable': false,
            },
            {
              'kind': 'retention',
              'source': 'qbittorrent',
              'title': 'The Matrix download',
              'potentialBytes': 4000000000,
              'evidence': [
                'download_complete',
                'import_verified',
                'retention_policy_satisfied',
              ],
              'actionAvailable': false,
            },
          ],
    'candidateCounts': state == 'incomplete'
        ? {'duplicate': 0, 'transcode': 0, 'retention': 0}
        : {'duplicate': 1, 'transcode': 1, 'retention': 1},
    'totalPotentialBytes': state == 'incomplete' ? 0 : 10000000000,
    'truncated': false,
    'actionAvailable': false,
  },
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
    expect(snapshot.savingsPlan.candidates.length, 3);
    expect(
      snapshot.savingsPlan.candidates.map((value) => value.kind),
      MediaArchiveSavingKind.values,
    );
    expect(snapshot.savingsPlan.actionAvailable, isFalse);
  });

  testWidgets('detail explains all bounded plan lanes without actions', (
    tester,
  ) async {
    final snapshot = MediaArchiveHealthSnapshot.fromJson(detailArchiveJson());
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      app(MediaArchiveHealthDetailScreen(snapshot: snapshot), scale: 2),
    );
    Future<void> reveal(String text) async {
      await tester.scrollUntilVisible(
        find.text(text),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(find.text(text), findsOneWidget);
    }

    await reveal('Duplicates');
    await reveal('The Matrix duplicate');
    expect(
      find.bySemanticsLabel(RegExp(r'The Matrix duplicate.*4\.0 GB')),
      findsOneWidget,
    );
    await reveal('Transcode review');
    await reveal('Home video');
    await reveal('Retention review');
    await reveal('The Matrix download');
    expect(find.byType(CupertinoButton), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
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
    expect(find.text('Pilot'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('The Matrix download'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('The Matrix download'), findsOneWidget);
  });

  testWidgets(
    'detail is responsive at 600 and 1280 with 2x text and TalkBack',
    (tester) async {
      final snapshot = MediaArchiveHealthSnapshot.fromJson(detailArchiveJson());
      addTearDown(tester.view.reset);
      for (final width in [600.0, 1280.0]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          app(
            KeyedSubtree(
              key: ValueKey(width),
              child: MediaArchiveHealthDetailScreen(snapshot: snapshot),
            ),
            scale: 2,
          ),
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
