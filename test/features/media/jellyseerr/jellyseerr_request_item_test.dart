import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_request_item.dart';

void main() {
  group('JellyseerrRequestStatus.fromCode', () {
    test('maps known codes and leaves missing evidence unknown', () {
      expect(
        JellyseerrRequestStatus.fromCode(1),
        JellyseerrRequestStatus.pendingApproval,
      );
      expect(
        JellyseerrRequestStatus.fromCode(2),
        JellyseerrRequestStatus.approved,
      );
      expect(
        JellyseerrRequestStatus.fromCode(3),
        JellyseerrRequestStatus.declined,
      );
      expect(
        JellyseerrRequestStatus.fromCode(null),
        JellyseerrRequestStatus.unknown,
      );
      expect(
        JellyseerrRequestStatus.fromCode(99),
        JellyseerrRequestStatus.unknown,
      );
    });
  });

  group('JellyseerrRequestItem', () {
    test('reads type/status field aliases and resolves media title', () {
      final item = JellyseerrRequestItem.fromJson({
        'id': 10,
        'type': 'movie',
        'status': 2,
        'media': {'tmdbId': 603, 'title': 'The Matrix'},
      });

      expect(item.mediaType, 'movie');
      expect(item.status, JellyseerrRequestStatus.approved);
      expect(item.displayTitle, 'The Matrix');
    });

    test(
      'falls back to a generic "type #id" label when no title is available',
      () {
        final movie = JellyseerrRequestItem.fromJson({
          'id': 10,
          'type': 'movie',
          'media': {'tmdbId': 603},
        });
        expect(movie.displayTitle, 'Movie #603');

        final tv = JellyseerrRequestItem.fromJson({'id': 11, 'type': 'tv'});
        expect(tv.displayTitle, 'TV show #11');
      },
    );
  });
}
