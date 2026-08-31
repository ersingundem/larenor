import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/media/jellyseerr/data/models/jellyseerr_result.dart';

void main() {
  group('JellyseerrMediaStatus.fromCode', () {
    test('maps known codes', () {
      expect(JellyseerrMediaStatus.fromCode(2), JellyseerrMediaStatus.pending);
      expect(
        JellyseerrMediaStatus.fromCode(3),
        JellyseerrMediaStatus.processing,
      );
      expect(
        JellyseerrMediaStatus.fromCode(4),
        JellyseerrMediaStatus.partiallyAvailable,
      );
      expect(
        JellyseerrMediaStatus.fromCode(5),
        JellyseerrMediaStatus.available,
      );
    });

    test('falls back to unknown for null or unrecognized codes', () {
      expect(
        JellyseerrMediaStatus.fromCode(null),
        JellyseerrMediaStatus.unknown,
      );
      expect(JellyseerrMediaStatus.fromCode(99), JellyseerrMediaStatus.unknown);
      expect(JellyseerrMediaStatus.fromCode(1), JellyseerrMediaStatus.unknown);
    });
  });

  group('JellyseerrResult', () {
    test('parses camelCase fields and resolves status through mediaInfo', () {
      final result = JellyseerrResult.fromJson({
        'id': 1,
        'mediaType': 'movie',
        'title': 'The Matrix',
        'posterPath': '/abc.jpg',
        'overview': 'A hacker...',
        'mediaInfo': {'status': 5},
      });

      expect(result.displayTitle, 'The Matrix');
      expect(result.isTv, isFalse);
      expect(result.status, JellyseerrMediaStatus.available);
    });

    test(
      'falls back to name for tv results and unknown status without mediaInfo',
      () {
        final result = JellyseerrResult.fromJson({
          'id': 2,
          'mediaType': 'tv',
          'name': 'Breaking Bad',
        });

        expect(result.displayTitle, 'Breaking Bad');
        expect(result.isTv, isTrue);
        expect(result.status, JellyseerrMediaStatus.unknown);
      },
    );

    test(
      'displayTitle falls back to Unknown when neither title nor name is set',
      () {
        final result = JellyseerrResult.fromJson({
          'id': 3,
          'mediaType': 'movie',
        });
        expect(result.displayTitle, 'Unknown');
      },
    );
  });
}
