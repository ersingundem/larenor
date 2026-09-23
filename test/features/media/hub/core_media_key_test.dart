import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/hub/domain/core_media_key.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';

void main() {
  group('CoreMediaKey.fromIdentity', () {
    test('maps only the canonical Core id for each media kind', () {
      expect(
        CoreMediaKey.fromIdentity(
          const MediaIdentity(
            kind: MediaKind.movie,
            tmdbId: 603,
            tvdbId: 999,
            imdbId: 'tt0133093',
          ),
        )?.value,
        'movie:tmdb:603',
      );
      expect(
        CoreMediaKey.fromIdentity(
          const MediaIdentity(
            kind: MediaKind.tv,
            tmdbId: 1396,
            tvdbId: 81189,
            imdbId: 'tt0903747',
          ),
        )?.value,
        'series:tvdb:81189',
      );
    });

    test('does not substitute a provider id Core does not accept', () {
      expect(
        CoreMediaKey.fromIdentity(
          const MediaIdentity(kind: MediaKind.movie, tvdbId: 81189),
        ),
        isNull,
      );
      expect(
        CoreMediaKey.fromIdentity(
          const MediaIdentity(kind: MediaKind.tv, tmdbId: 1396),
        ),
        isNull,
      );
      expect(
        CoreMediaKey.fromIdentity(
          const MediaIdentity(kind: MediaKind.movie, imdbId: 'tt0133093'),
        ),
        isNull,
      );
    });

    test('rejects zero, negative and over-12-digit ids', () {
      for (final invalid in <int>[0, -1, 1000000000000]) {
        expect(
          CoreMediaKey.fromIdentity(
            MediaIdentity(kind: MediaKind.movie, tmdbId: invalid),
          ),
          isNull,
        );
        expect(
          CoreMediaKey.fromIdentity(
            MediaIdentity(kind: MediaKind.tv, tvdbId: invalid),
          ),
          isNull,
        );
      }
    });

    test('accepts both ends of the Core numeric id range', () {
      expect(
        CoreMediaKey.fromIdentity(
          const MediaIdentity(kind: MediaKind.movie, tmdbId: 1),
        )?.value,
        'movie:tmdb:1',
      );
      expect(
        CoreMediaKey.fromIdentity(
          const MediaIdentity(kind: MediaKind.tv, tvdbId: 999999999999),
        )?.value,
        'series:tvdb:999999999999',
      );
    });

    test('the serialized key contains no title, URL, token or Jellyfin id', () {
      final key = CoreMediaKey.fromIdentity(
        const MediaIdentity(
          kind: MediaKind.movie,
          tmdbId: 603,
          imdbId: 'jellyfin-item-token-like-value',
        ),
      );

      expect(key?.value, 'movie:tmdb:603');
      expect(key.toString(), 'movie:tmdb:603');
      expect(key?.value, isNot(contains('jellyfin')));
    });
  });
}
