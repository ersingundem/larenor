import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/arr/data/models/arr_calendar_item.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_title.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_result.dart';

String? fakeImage(String id, {String type = 'Primary', String? tag}) =>
    'http://jf/$id/$type${tag == null ? '' : '?tag=$tag'}';

String? fakePoster(String? path) =>
    path == null ? null : 'https://image.tmdb.org/t/p/w300$path';

void main() {
  group('mediaTitleFromJellyfin', () {
    test('maps a film, marking it playable and in-library', () {
      final title = mediaTitleFromJellyfin(
        const JellyfinItem(
          id: 'i1',
          name: 'The Matrix',
          type: 'Movie',
          productionYear: 1999,
          providerIds: {'Tmdb': '603'},
          imageTags: {'Primary': 'abc'},
        ),
        imageUrl: fakeImage,
      )!;

      expect(title.identity.tmdbId, 603);
      expect(title.identity.kind, MediaKind.movie);
      expect(title.availability, MediaAvailability.inLibrary);
      expect(title.isPlayable, isTrue);
      expect(title.posterUrl, 'http://jf/i1/Primary?tag=abc');
      expect(title.year, 1999);
    });

    test('folds an episode up to its series name', () {
      final title = mediaTitleFromJellyfin(
        const JellyfinItem(
          id: 'e1',
          name: 'Pilot',
          type: 'Episode',
          seriesName: 'Breaking Bad',
          providerIds: {'Tvdb': '81189'},
        ),
        imageUrl: fakeImage,
      )!;

      expect(title.title, 'Breaking Bad');
      expect(title.identity.kind, MediaKind.tv);
    });

    test('returns null for item types the hub does not handle', () {
      expect(
        mediaTitleFromJellyfin(
          const JellyfinItem(id: 'a1', name: 'Album', type: 'MusicAlbum'),
          imageUrl: fakeImage,
        ),
        isNull,
      );
    });
  });

  group('mediaTitleFromJellyseerr', () {
    JellyseerrResult result({
      int? status,
      String? jellyfinMediaId,
      String mediaType = 'movie',
    }) => JellyseerrResult(
      id: 603,
      mediaType: mediaType,
      title: 'The Matrix',
      posterPath: '/p.jpg',
      releaseDate: '1999-03-31',
      mediaInfo: status == null && jellyfinMediaId == null
          ? null
          : JellyseerrMediaInfo(
              status: status,
              jellyfinMediaId: jellyfinMediaId,
            ),
    );

    test('an unrequested result is not available', () {
      final title = mediaTitleFromJellyseerr(
        result(),
        posterUrl: fakePoster,
        backdropUrl: fakePoster,
      );
      expect(title.availability, MediaAvailability.notAvailable);
      expect(title.identity.tmdbId, 603);
      expect(title.year, 1999);
    });

    test('a pending request reads as requested', () {
      final title = mediaTitleFromJellyseerr(
        result(status: 2),
        posterUrl: fakePoster,
        backdropUrl: fakePoster,
      );
      expect(title.availability, MediaAvailability.requested);
    });

    test('an available result carries the Jellyfin bridge id', () {
      final title = mediaTitleFromJellyseerr(
        result(status: 5, jellyfinMediaId: 'jf-42'),
        posterUrl: fakePoster,
        backdropUrl: fakePoster,
      );
      expect(title.availability, MediaAvailability.inLibrary);
      expect(title.jellyfinItemId, 'jf-42');
      expect(title.isPlayable, isTrue);
    });

    test('a tv result resolves to the tv kind', () {
      final title = mediaTitleFromJellyseerr(
        result(mediaType: 'tv'),
        posterUrl: fakePoster,
        backdropUrl: fakePoster,
      );
      expect(title.identity.kind, MediaKind.tv);
      expect(title.isTv, isTrue);
    });
  });

  group('mediaTitleFromCalendar', () {
    test('an unaired entry reads as monitored', () {
      final title = mediaTitleFromCalendar(
        ArrCalendarItem.fromJson(const {
          'title': 'Ep',
          'hasFile': false,
          'series': {'title': 'Show', 'tvdbId': 5},
        }),
        MediaKind.tv,
      )!;

      expect(title.title, 'Show');
      expect(title.availability, MediaAvailability.monitored);
      expect(title.identity.tvdbId, 5);
    });

    test('is skipped entirely when it carries no external ids', () {
      expect(
        mediaTitleFromCalendar(
          ArrCalendarItem.fromJson(const {'title': 'Mystery'}),
          MediaKind.movie,
        ),
        isNull,
      );
    });
  });

  group('dedupeTitles', () {
    MediaTitle t(String name, {int? tmdb, int? tvdb, MediaKind? kind}) =>
        MediaTitle(
          identity: MediaIdentity(
            kind: kind ?? MediaKind.movie,
            tmdbId: tmdb,
            tvdbId: tvdb,
          ),
          title: name,
          availability: MediaAvailability.notAvailable,
        );

    test(
      'collapses the same title found in two services, keeping the first',
      () {
        final out = dedupeTitles([
          t('Library copy', tmdb: 603),
          t('Catalogue copy', tmdb: 603),
        ]);

        expect(out, hasLength(1));
        expect(out.single.title, 'Library copy');
      },
    );

    test('collapses records that overlap on a secondary id', () {
      final out = dedupeTitles([
        MediaTitle(
          identity: const MediaIdentity(
            kind: MediaKind.tv,
            tmdbId: 1396,
            tvdbId: 81189,
          ),
          title: 'From Jellyfin',
          availability: MediaAvailability.inLibrary,
        ),
        t('From Sonarr', tvdb: 81189, kind: MediaKind.tv),
      ]);

      expect(out, hasLength(1));
      expect(out.single.title, 'From Jellyfin');
    });

    test('keeps genuinely different titles', () {
      final out = dedupeTitles([t('A', tmdb: 1), t('B', tmdb: 2)]);
      expect(out, hasLength(2));
    });

    test('keeps a film and a series that share a tmdb id', () {
      final out = dedupeTitles([
        t('Film', tmdb: 1),
        t('Series', tmdb: 1, kind: MediaKind.tv),
      ]);
      expect(out, hasLength(2));
    });

    test('never collapses id-less titles onto each other', () {
      final out = dedupeTitles([t('One'), t('Two')]);
      expect(out, hasLength(2));
    });
  });
}
