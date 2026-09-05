import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/arr/data/models/arr_library_item.dart';
import 'package:larenor/features/media/arr/data/models/arr_queue_item.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_library_index.dart';
import 'package:larenor/features/media/hub/domain/media_title.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';

JellyfinItem jf(
  String id, {
  String type = 'Movie',
  Map<String, String>? providerIds,
  double? played,
}) => JellyfinItem(
  id: id,
  name: id,
  type: type,
  locationType: 'FileSystem',
  playAccess: 'Full',
  providerIds: providerIds,
  userData: played == null ? null : JellyfinUserData(playedPercentage: played),
);

void main() {
  group('MediaIdentity', () {
    test('key prefers tmdb, then tvdb, then imdb', () {
      expect(
        const MediaIdentity(kind: MediaKind.movie, tmdbId: 1, tvdbId: 2).key,
        'movie:tmdb:1',
      );
      expect(
        const MediaIdentity(kind: MediaKind.tv, tvdbId: 2, imdbId: 'tt3').key,
        'tv:tvdb:2',
      );
      expect(
        const MediaIdentity(kind: MediaKind.tv, imdbId: 'tt3').key,
        'tv:imdb:tt3',
      );
    });

    test('matches on any shared id', () {
      const a = MediaIdentity(kind: MediaKind.movie, tmdbId: 1, imdbId: 'tt9');
      const b = MediaIdentity(kind: MediaKind.movie, imdbId: 'tt9');
      expect(a.matches(b), isTrue);
    });

    test('never matches across kinds, even with the same numeric id', () {
      const movie = MediaIdentity(kind: MediaKind.movie, tmdbId: 1);
      const tv = MediaIdentity(kind: MediaKind.tv, tmdbId: 1);
      expect(movie.matches(tv), isFalse);
    });

    test('does not match when the ids they share disagree', () {
      const a = MediaIdentity(kind: MediaKind.movie, tmdbId: 1);
      const b = MediaIdentity(kind: MediaKind.movie, tmdbId: 2);
      expect(a.matches(b), isFalse);
    });

    test('does not match when they share no id at all', () {
      const a = MediaIdentity(kind: MediaKind.movie, tmdbId: 1);
      const b = MediaIdentity(kind: MediaKind.movie, tvdbId: 5);
      expect(a.matches(b), isFalse);
    });

    test('merging keeps every known id', () {
      const a = MediaIdentity(kind: MediaKind.tv, tmdbId: 1);
      const b = MediaIdentity(kind: MediaKind.tv, tvdbId: 2, imdbId: 'tt3');
      final merged = a.mergedWith(b);
      expect(merged.tmdbId, 1);
      expect(merged.tvdbId, 2);
      expect(merged.imdbId, 'tt3');
    });
  });

  group('JellyfinItem provider ids', () {
    test('reads Tmdb/Tvdb/Imdb out of ProviderIds', () {
      final item = jf(
        'a',
        providerIds: const {
          'Tmdb': '603',
          'Tvdb': '81189',
          'Imdb': 'tt0133093',
        },
      );
      expect(item.tmdbId, 603);
      expect(item.tvdbId, 81189);
      expect(item.imdbId, 'tt0133093');
    });

    test('is case-insensitive, since plugins disagree on casing', () {
      expect(jf('a', providerIds: const {'tmdb': '42'}).tmdbId, 42);
      expect(jf('a', providerIds: const {'TMDB': '42'}).tmdbId, 42);
    });

    test('returns null with no ids, empty values, or junk', () {
      expect(jf('a').tmdbId, isNull);
      expect(jf('a', providerIds: const {'Tmdb': ''}).tmdbId, isNull);
      expect(jf('a', providerIds: const {'Tmdb': 'abc'}).tmdbId, isNull);
    });
  });

  group('MediaLibraryIndex', () {
    test('a Jellyfin item resolves as playable and in-library', () {
      final index = MediaLibraryIndex.build(
        jellyfinItems: [
          jf('item1', providerIds: const {'Tmdb': '603'}),
        ],
      );
      const identity = MediaIdentity(kind: MediaKind.movie, tmdbId: 603);

      expect(index.lookup(identity)?.jellyfinItemId, 'item1');
      expect(index.availabilityOf(identity), MediaAvailability.inLibrary);
    });

    test('ignores Jellyfin items with no external ids at all', () {
      final index = MediaLibraryIndex.build(jellyfinItems: [jf('item1')]);
      expect(index.isEmpty, isTrue);
    });

    test('a monitored Radarr movie with no file reads as monitored', () {
      final index = MediaLibraryIndex.build(
        radarrLibrary: [
          const ArrLibraryItem(
            id: 7,
            title: 'The Matrix',
            monitored: true,
            tmdbId: 603,
            hasFile: false,
          ),
        ],
      );
      const identity = MediaIdentity(kind: MediaKind.movie, tmdbId: 603);

      expect(index.availabilityOf(identity), MediaAvailability.monitored);
      expect(index.lookup(identity)?.arrItemId, 7);
    });

    test('a Radarr movie with its file is available without playback', () {
      final index = MediaLibraryIndex.build(
        radarrLibrary: [
          const ArrLibraryItem(
            id: 7,
            title: 'The Matrix',
            monitored: true,
            tmdbId: 603,
            hasFile: true,
          ),
        ],
      );
      expect(
        index.availabilityOf(
          const MediaIdentity(kind: MediaKind.movie, tmdbId: 603),
        ),
        MediaAvailability.available,
      );
    });

    test('a queued grab reads as downloading, with progress', () {
      final index = MediaLibraryIndex.build(
        queue: [
          const ArrQueueItem(
            id: 1,
            title: 'The Matrix',
            status: 'downloading',
            progressFraction: 0.4,
            movieId: 7,
            tmdbId: 603,
          ),
        ],
      );
      const identity = MediaIdentity(kind: MediaKind.movie, tmdbId: 603);

      expect(index.availabilityOf(identity), MediaAvailability.downloading);
      expect(index.lookup(identity)?.downloadProgress, 0.4);
    });

    test('Jellyfin playability outranks an *arr grab for the same title', () {
      final index = MediaLibraryIndex.build(
        jellyfinItems: [
          jf('item1', providerIds: const {'Tmdb': '603'}),
        ],
        radarrLibrary: [
          const ArrLibraryItem(
            id: 7,
            title: 'The Matrix',
            monitored: true,
            tmdbId: 603,
            hasFile: false,
          ),
        ],
      );
      final entry = index.lookup(
        const MediaIdentity(kind: MediaKind.movie, tmdbId: 603),
      );

      expect(entry?.availability, MediaAvailability.inLibrary);
      // ...and it still knows the Radarr row, for Bazarr/monitored state.
      expect(entry?.arrItemId, 7);
      expect(entry?.monitored, isTrue);
    });

    test('a TVDB-only Sonarr entry joins a TMDB-only Jellyfin one', () {
      // Neither record alone could be matched to the other; they meet
      // because a third record knows both ids.
      final index = MediaLibraryIndex.build(
        jellyfinItems: [
          jf(
            'show1',
            type: 'Series',
            providerIds: const {'Tmdb': '1396', 'Tvdb': '81189'},
          ),
        ],
        sonarrLibrary: [
          const ArrLibraryItem(
            id: 3,
            title: 'Breaking Bad',
            monitored: true,
            tvdbId: 81189,
          ),
        ],
      );

      final byTmdb = index.lookup(
        const MediaIdentity(kind: MediaKind.tv, tmdbId: 1396),
      );
      final byTvdb = index.lookup(
        const MediaIdentity(kind: MediaKind.tv, tvdbId: 81189),
      );

      expect(byTmdb?.jellyfinSeriesId, 'show1');
      expect(byTmdb?.jellyfinItemId, isNull);
      expect(byTmdb?.arrItemId, 3);
      expect(byTvdb?.jellyfinSeriesId, 'show1');
    });

    test('a movie and a series sharing a tmdb id stay separate', () {
      final index = MediaLibraryIndex.build(
        jellyfinItems: [
          jf('movie1', providerIds: const {'Tmdb': '1'}),
        ],
        sonarrLibrary: [
          const ArrLibraryItem(
            id: 3,
            title: 'Something',
            monitored: true,
            tmdbId: 1,
          ),
        ],
      );

      expect(
        index
            .lookup(const MediaIdentity(kind: MediaKind.movie, tmdbId: 1))
            ?.jellyfinItemId,
        'movie1',
      );
      expect(
        index
            .lookup(const MediaIdentity(kind: MediaKind.tv, tmdbId: 1))
            ?.jellyfinItemId,
        isNull,
      );
    });

    test('enrich fills a bare catalogue title in from the index', () {
      final index = MediaLibraryIndex.build(
        jellyfinItems: [
          jf('item1', providerIds: const {'Tmdb': '603'}, played: 35),
        ],
      );

      final enriched = index.enrich(
        const MediaTitle(
          identity: MediaIdentity(kind: MediaKind.movie, tmdbId: 603),
          title: 'The Matrix',
          availability: MediaAvailability.notAvailable,
        ),
      );

      expect(enriched.availability, MediaAvailability.inLibrary);
      expect(enriched.jellyfinItemId, 'item1');
      expect(enriched.playedFraction, closeTo(0.35, 0.001));
      expect(enriched.isPlayable, isTrue);
    });

    test('enrich leaves an unknown title alone', () {
      final enriched = MediaLibraryIndex.empty.enrich(
        const MediaTitle(
          identity: MediaIdentity(kind: MediaKind.movie, tmdbId: 1),
          title: 'Nothing',
          availability: MediaAvailability.notAvailable,
        ),
      );
      expect(enriched.availability, MediaAvailability.notAvailable);
      expect(enriched.isPlayable, isFalse);
    });

    test('a pending request survives when the index knows nothing yet', () {
      final enriched = MediaLibraryIndex.empty.enrich(
        const MediaTitle(
          identity: MediaIdentity(kind: MediaKind.movie, tmdbId: 1),
          title: 'Requested thing',
          availability: MediaAvailability.requested,
        ),
        preserveVerifiedPlayback: true,
      );
      expect(enriched.availability, MediaAvailability.requested);
    });

    test('a request is superseded once the grab actually starts', () {
      final index = MediaLibraryIndex.build(
        queue: [
          const ArrQueueItem(
            id: 1,
            title: 'Requested thing',
            status: 'downloading',
            progressFraction: 0.1,
            movieId: 4,
            tmdbId: 1,
          ),
        ],
      );

      final enriched = index.enrich(
        const MediaTitle(
          identity: MediaIdentity(kind: MediaKind.movie, tmdbId: 1),
          title: 'Requested thing',
          availability: MediaAvailability.requested,
        ),
      );
      expect(enriched.availability, MediaAvailability.downloading);
    });
  });

  group('ArrLibraryItem', () {
    test('parses external ids and picks the poster image', () {
      final item = ArrLibraryItem.fromJson(const {
        'id': 12,
        'title': 'The Matrix',
        'monitored': true,
        'year': 1999,
        'tmdbId': 603,
        'imdbId': 'tt0133093',
        'hasFile': true,
        'images': [
          {'coverType': 'fanart', 'remoteUrl': 'http://x/fan.jpg'},
          {'coverType': 'poster', 'remoteUrl': 'http://x/poster.jpg'},
        ],
      });

      expect(item.id, 12);
      expect(item.tmdbId, 603);
      expect(item.imdbId, 'tt0133093');
      expect(item.posterUrl, 'http://x/poster.jpg');
      expect(item.isComplete, isTrue);
    });

    test('a series counts as complete only with every episode present', () {
      ArrLibraryItem withStats(int have, int total) => ArrLibraryItem.fromJson({
        'id': 1,
        'title': 'Show',
        'monitored': true,
        'tvdbId': 5,
        'statistics': {
          'episodeCount': total,
          'episodeFileCount': have,
          'totalEpisodeCount': total,
        },
      });

      expect(withStats(10, 10).isComplete, isTrue);
      expect(withStats(4, 10).isComplete, isFalse);
      expect(withStats(0, 0).isComplete, isFalse);
    });
  });

  group('ArrQueueItem', () {
    test('lifts ids out of the nested series object', () {
      final item = ArrQueueItem.fromJson(const {
        'id': 1,
        'status': 'downloading',
        'size': 100,
        'sizeleft': 25,
        'seriesId': 3,
        'downloadId': 'ABCDEF123',
        'series': {'title': 'Breaking Bad', 'tvdbId': 81189, 'tmdbId': 1396},
      });

      expect(item.title, 'Breaking Bad');
      expect(item.seriesId, 3);
      expect(item.tvdbId, 81189);
      expect(item.tmdbId, 1396);
      expect(item.downloadId, 'ABCDEF123');
      expect(item.progressFraction, closeTo(0.75, 0.001));
    });

    test('reads a movie grab from the nested movie object', () {
      final item = ArrQueueItem.fromJson(const {
        'id': 2,
        'status': 'downloading',
        'movieId': 9,
        'movie': {'title': 'The Matrix', 'tmdbId': 603},
      });

      expect(item.movieId, 9);
      expect(item.tmdbId, 603);
      expect(item.progressFraction, isNull);
    });
  });
}
