import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/arr/data/models/arr_lookup_result.dart';

void main() {
  test('parses using the given idFieldName (tvdbId for Sonarr)', () {
    final result = ArrLookupResult.fromJson({
      'title': 'Breaking Bad',
      'tvdbId': 81189,
      'tmdbId': 1396,
      'year': 2008,
      'overview': 'A chemistry teacher...',
      'images': [
        {'coverType': 'fanart', 'remoteUrl': 'https://x/fanart.jpg'},
        {'coverType': 'poster', 'remoteUrl': 'https://x/poster.jpg'},
      ],
    }, idFieldName: 'tvdbId');

    expect(result.title, 'Breaking Bad');
    expect(result.remoteId, 81189);
    expect(result.year, 2008);
    expect(result.posterUrl, 'https://x/poster.jpg');
    expect(result.alreadyAdded, isFalse);
  });

  test('parses using tmdbId for Radarr', () {
    final result = ArrLookupResult.fromJson({
      'title': 'The Matrix',
      'tmdbId': 603,
    }, idFieldName: 'tmdbId');

    expect(result.remoteId, 603);
  });

  test('falls back from remoteUrl to url when remoteUrl is absent', () {
    final result = ArrLookupResult.fromJson({
      'title': 'X',
      'tmdbId': 1,
      'images': [
        {'coverType': 'poster', 'url': '/local/poster.jpg'},
      ],
    }, idFieldName: 'tmdbId');

    expect(result.posterUrl, '/local/poster.jpg');
  });

  test('alreadyAdded is true when the server already assigned an id', () {
    final result = ArrLookupResult.fromJson({
      'title': 'X',
      'tmdbId': 1,
      'id': 42,
    }, idFieldName: 'tmdbId');

    expect(result.alreadyAdded, isTrue);
  });

  test('keeps the full raw JSON for round-tripping into the add call', () {
    final json = {
      'title': 'X',
      'tmdbId': 1,
      'genres': ['Action'],
    };
    final result = ArrLookupResult.fromJson(json, idFieldName: 'tmdbId');
    expect(result.raw, json);
  });

  test('defaults missing title to Unknown and missing id field to 0', () {
    final result = ArrLookupResult.fromJson({}, idFieldName: 'tmdbId');
    expect(result.title, 'Unknown');
    expect(result.remoteId, 0);
    expect(result.posterUrl, isNull);
  });
}
