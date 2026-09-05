import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/media/arr/data/models/arr_library_item.dart';
import 'package:larenor/features/media/arr/data/models/arr_queue_item.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_library_index.dart';
import 'package:larenor/features/media/hub/domain/media_read_result.dart';
import 'package:larenor/features/media/hub/domain/media_title.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_request_item.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_result.dart';

const movieId = MediaIdentity(kind: MediaKind.movie, tmdbId: 1);
const seriesId = MediaIdentity(kind: MediaKind.tv, tmdbId: 2);
JellyfinItem movie({String id = 'movie'}) => JellyfinItem(
  id: id,
  name: 'Film',
  type: 'Movie',
  providerIds: const {'Tmdb': '1'},
  locationType: 'FileSystem',
  playAccess: 'Full',
);

void main() {
  group('official Arr queue states', () {
    // QueueStatus and TrackedDownload enums in Sonarr/Radarr source; these are
    // independent fields, not an assumed progress percentage state machine.
    const statusStages = {
      'queued': MediaAvailability.queued,
      'paused': MediaAvailability.paused,
      'downloading': MediaAvailability.downloading,
      'completed': MediaAvailability.importing,
      'failed': MediaAvailability.failed,
      'warning': MediaAvailability.failed,
      'delay': MediaAvailability.queued,
      'fallback': MediaAvailability.queued,
      'downloadClientUnavailable': MediaAvailability.unknown,
      'futureStatus': MediaAvailability.unknown,
    };
    for (final entry in statusStages.entries) {
      test('${entry.key} remains distinct without inventing progress', () {
        final index = MediaLibraryIndex.build(
          queue: [
            ArrQueueItem(
              id: 1,
              title: 'Film',
              status: entry.key,
              movieId: 5,
              tmdbId: 1,
            ),
          ],
        );
        final title = index.titleFor(movieId)!;
        expect(title.availability, entry.value);
        expect(title.downloadProgress, isNull);
        expect(title.transfers.single.stage, entry.value);
        expect(title.isPlayable, isFalse);
      });
    }
    const trackedStages = {
      'importPending': MediaAvailability.importing,
      'importing': MediaAvailability.importing,
      'imported': MediaAvailability.available,
      'importBlocked': MediaAvailability.failed,
      'failedPending': MediaAvailability.failed,
      'failed': MediaAvailability.failed,
      'ignored': MediaAvailability.unknown,
    };
    for (final entry in trackedStages.entries) {
      test('${entry.key} overrides download-client completion', () {
        final transfer = mediaTransferFromQueue(
          ArrQueueItem(
            id: 1,
            title: 'Film',
            status: 'completed',
            trackedDownloadState: entry.key,
          ),
        );
        expect(transfer.stage, entry.value);
      });
    }
    test('import warning is visible even when bytes reached 100 percent', () {
      final transfer = mediaTransferFromQueue(
        const ArrQueueItem(
          id: 1,
          title: 'Film',
          status: 'completed',
          progressFraction: 1,
          trackedDownloadState: 'importPending',
          trackedDownloadStatus: 'warning',
        ),
      );
      expect(transfer.stage, MediaAvailability.failed);
      expect(transfer.progress, 1);
    });
    test('invalid byte counts and nonfinite direct progress stay unknown', () {
      for (final values in [
        {'size': double.infinity, 'sizeleft': 0},
        {'size': 100, 'sizeleft': -1},
        {'size': 100, 'sizeleft': 101},
        {'size': 100, 'sizeleft': double.nan},
      ]) {
        expect(ArrQueueItem.fromJson(values).progressFraction, isNull);
      }
      for (final value in [double.nan, double.infinity, -1.0, 1.1]) {
        expect(
          mediaTransferFromQueue(
            ArrQueueItem(
              id: 1,
              title: 'x',
              status: 'downloading',
              progressFraction: value,
            ),
          ).progress,
          isNull,
        );
      }
      expect(
        mediaTransferFromQueue(
          const ArrQueueItem(
            id: 1,
            title: 'x',
            status: 'downloading',
            progressFraction: 0,
          ),
        ).progress,
        0,
      );
    });
  });

  test('playable library and failed/queued transfers coexist', () {
    final index = MediaLibraryIndex.build(
      jellyfinItems: [movie()],
      queue: const [
        ArrQueueItem(
          id: 2,
          title: 'Film',
          movieId: 5,
          tmdbId: 1,
          status: 'queued',
          progressFraction: .1,
        ),
        ArrQueueItem(
          id: 1,
          title: 'Film',
          movieId: 5,
          tmdbId: 1,
          status: 'failed',
          progressFraction: .9,
        ),
      ],
    );
    final title = index.titleFor(movieId)!;
    expect(title.isPlayable, isTrue);
    expect(title.availability, MediaAvailability.inLibrary);
    expect(title.transfers.map((t) => t.id), ['1', '2']);
    expect(title.transfers.map((t) => t.stage), [
      MediaAvailability.failed,
      MediaAvailability.queued,
    ]);
    expect(title.downloadProgress, isNull); // no unweighted fake title average
    expect(() => title.transfers.clear(), throwsUnsupportedError);
  });

  test(
    'partial seasons keep specials and unknown counts, no playback inference',
    () {
      final show = ArrLibraryItem.fromJson({
        'id': 4,
        'title': 'Show',
        'monitored': true,
        'tmdbId': 2,
        'statistics': {
          'episodeCount': 4,
          'episodeFileCount': 4,
          'totalEpisodeCount': 10,
        },
        'seasons': [
          {
            'seasonNumber': 1,
            'statistics': {
              'episodeCount': 4,
              'episodeFileCount': 4,
              'totalEpisodeCount': 10,
            },
          },
          {'seasonNumber': 0},
        ],
      });
      final title = MediaLibraryIndex.build(sonarrLibrary: [show])
          .titleFor(seriesId)!;
      expect(show.isComplete, isFalse);
      expect(title.availability, MediaAvailability.partiallyAvailable);
      expect(title.seasonCoverage.map((s) => s.seasonNumber), [0, 1]);
      expect(title.seasonCoverage.first.expectedEpisodeCount, isNull);
      expect(title.seasonCoverage.last.expectedEpisodeCount, 10);
      expect(title.seasonCoverage.last.downloadedEpisodeCount, 4);
      expect(title.seasonCoverage.last.playableEpisodeCount, isNull);
      expect(title.isPlayable, isFalse);
    },
  );

  test('monitored denominator alone cannot prove complete known series', () {
    final item = ArrLibraryItem.fromJson({
      'statistics': {'episodeCount': 4, 'episodeFileCount': 4},
    });
    expect(item.isComplete, isFalse);
    expect(
      ArrLibraryItem.fromJson({'statistics': {}}).statistics?.episodeFileCount,
      isNull,
    );
    expect(
      () => ArrLibraryItem.fromJson({
        'statistics': {'episodeFileCount': -1},
      }),
      throwsFormatException,
    );
    expect(
      () => ArrLibraryItem.fromJson({
        'seasons': [
          {'seasonNumber': 0},
          {'seasonNumber': 0},
        ],
      }),
      throwsFormatException,
    );
  });

  test('series container and unknown movie DTO never become Play targets', () {
    final index = MediaLibraryIndex.build(
      jellyfinItems: const [
        JellyfinItem(
          id: 'show',
          name: 'Show',
          type: 'Series',
          providerIds: {'Tmdb': '2'},
        ),
        JellyfinItem(
          id: 'unknown',
          name: 'Film',
          type: 'Movie',
          providerIds: {'Tmdb': '1'},
        ),
      ],
    );
    expect(index.titleFor(seriesId)?.jellyfinSeriesId, 'show');
    expect(index.titleFor(seriesId)?.jellyfinItemId, isNull);
    expect(index.titleFor(movieId)?.isPlayable, isFalse);
  });

  test(
    'Seerr partial availability and bridge id cannot authorize playback',
    () {
      final title = mediaTitleFromJellyseerr(
        const JellyseerrResult(
          id: 2,
          mediaType: 'tv',
          name: 'Show',
          mediaInfo: JellyseerrMediaInfo(
            status: 4,
            jellyfinMediaId: 'foreign-server-show',
          ),
        ),
        posterUrl: (_) => null,
        backdropUrl: (_) => null,
      );
      expect(title.availability, MediaAvailability.partiallyAvailable);
      expect(title.jellyseerrMediaId, 'foreign-server-show');
      expect(title.jellyfinItemId, isNull);
      expect(title.isPlayable, isFalse);
    },
  );

  test('a Series container does not erase a fresh partial source status', () {
    final index = MediaLibraryIndex.build(
      jellyfinItems: const [
        JellyfinItem(
          id: 'show',
          name: 'Show',
          type: 'Series',
          providerIds: {'Tmdb': '2'},
        ),
      ],
    );
    final title = index.enrich(
      const MediaTitle(
        identity: seriesId,
        title: 'Show',
        availability: MediaAvailability.partiallyAvailable,
      ),
      preserveVerifiedPlayback: true,
    );
    expect(title.availability, MediaAvailability.partiallyAvailable);
    expect(title.jellyfinSeriesId, 'show');
    expect(title.isPlayable, isFalse);
  });

  test(
    'new account index clears old action/progress fields and null copy works',
    () {
      const previous = MediaTitle(
        identity: movieId,
        title: 'Film',
        availability: MediaAvailability.inLibrary,
        jellyfinItemId: 'old',
        jellyfinLookupId: 'old',
        jellyfinSeriesId: 'old-show',
        jellyseerrMediaId: 'old-seerr',
        arrItemId: 42,
        monitored: true,
        downloadProgress: .5,
        playedFraction: .9,
        requestStatus: JellyseerrRequestStatus.approved,
      );
      final cleared = MediaLibraryIndex.empty.enrich(previous);
      expect(cleared.isPlayable, isFalse);
      expect(cleared.jellyfinItemId, isNull);
      expect(cleared.jellyfinLookupId, isNull);
      expect(cleared.jellyfinSeriesId, isNull);
      expect(cleared.jellyseerrMediaId, isNull);
      expect(cleared.arrItemId, isNull);
      expect(cleared.monitored, isNull);
      expect(cleared.playedFraction, isNull);
      expect(cleared.downloadProgress, isNull);
      expect(cleared.requestStatus, isNull);
      expect(previous.copyWith(jellyfinItemId: null).jellyfinItemId, isNull);
      expect(
        previous.copyWith(jellyfinLookupId: null).jellyfinLookupId,
        isNull,
      );
      final replacement = MediaLibraryIndex.build(
        jellyfinItems: [movie(id: 'new')],
      ).enrich(previous);
      expect(replacement.jellyfinItemId, 'new');
      expect(replacement.jellyfinLookupId, 'new');
      expect(replacement.playedFraction, isNull);
    },
  );

  test(
    'conflicting primary id cannot use a shared secondary playback bridge',
    () {
      final index = MediaLibraryIndex.build(
        jellyfinItems: [
          movie().copyWith(providerIds: const {'Tmdb': '1', 'Imdb': 'tt1'}),
        ],
      );
      final foreign = index.enrich(
        const MediaTitle(
          identity: MediaIdentity(
            kind: MediaKind.movie,
            tmdbId: 999,
            imdbId: 'tt1',
          ),
          title: 'Wrong film',
          availability: MediaAvailability.inLibrary,
          jellyfinItemId: 'movie',
        ),
      );
      expect(foreign.isPlayable, isFalse);
    },
  );

  test('failed library read cannot leave old playable id looking current', () {
    final title =
        MediaLibraryIndex.build(
          readIssues: const [
            MediaReadIssue(
              MediaReadKey(IntegrationId.jellyfin, MediaReadOperation.library),
              HealthFailure.authentication,
            ),
          ],
        ).enrich(
          const MediaTitle(
            identity: movieId,
            title: 'Film',
            availability: MediaAvailability.inLibrary,
            jellyfinItemId: 'old',
          ),
        );
    expect(title.isStale, isTrue);
    expect(title.isPlayable, isFalse);
    expect(title.availability, MediaAvailability.unknown);
    expect(title.readIssues.single.failure, HealthFailure.authentication);
  });

  test(
    'request approval/failure is distinct from source media availability',
    () {
      for (final entry in {
        1: JellyseerrRequestStatus.pendingApproval,
        2: JellyseerrRequestStatus.approved,
        3: JellyseerrRequestStatus.declined,
        4: JellyseerrRequestStatus.failed,
        5: JellyseerrRequestStatus.completed,
        999: JellyseerrRequestStatus.unknown,
      }.entries) {
        final index = MediaLibraryIndex.build(
          requests: [
            JellyseerrRequestItem(
              id: 3,
              mediaType: 'movie',
              statusCode: entry.key,
              media: const JellyseerrRequestMedia(tmdbId: 1, title: 'Film'),
            ),
          ],
        );
        expect(index.titleFor(movieId)?.requestStatus, entry.value);
        expect(index.titleFor(movieId)?.isPlayable, isFalse);
      }
      expect(
        JellyseerrMediaStatus.fromCode(6),
        JellyseerrMediaStatus.blocklisted,
      );
      expect(JellyseerrMediaStatus.fromCode(7), JellyseerrMediaStatus.deleted);
    },
  );

  test('large library resolves missing nested queue ids by stable Arr id', () {
    final library = List.generate(
      5000,
      (i) => ArrLibraryItem(
        id: i + 1,
        title: 'Film ${i + 1}',
        monitored: true,
        tmdbId: i + 1,
      ),
    );
    final queue = List.generate(
      5000,
      (i) => ArrQueueItem(
        id: i + 1,
        title: 'Release',
        status: 'queued',
        movieId: i + 1,
      ),
    );
    final index = MediaLibraryIndex.build(radarrLibrary: library, queue: queue);
    for (var i = 1; i <= 5000; i++) {
      final title = index.titleFor(
        MediaIdentity(kind: MediaKind.movie, tmdbId: i),
      )!;
      expect(title.title, 'Film $i');
      expect(title.identity.key, 'movie:tmdb:$i');
      expect(title.availability, MediaAvailability.queued);
      expect(title.transfers, hasLength(1));
    }
  });
}
