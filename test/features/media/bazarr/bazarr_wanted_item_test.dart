import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/media/bazarr/data/models/bazarr_wanted_item.dart';

void main() {
  test('parses a movie wanted item with missing languages', () {
    final item = BazarrWantedItem.fromJson({
      'radarrId': 1,
      'title': 'The Matrix',
      'missing_subtitles': [
        {'code2': 'en', 'name': 'English'},
        {'code2': 'tr'},
      ],
    });

    expect(item.isMovie, isTrue);
    expect(item.radarrId, 1);
    expect(item.title, 'The Matrix');
    expect(item.missingLanguages, hasLength(2));
    expect(item.missingLanguages.first.label, 'English');
    expect(item.missingLanguages.last.label, 'tr');
  });

  test('parses an episode wanted item using sonarr-prefixed ids', () {
    final item = BazarrWantedItem.fromJson({
      'sonarrSeriesId': 10,
      'sonarrEpisodeId': 20,
      'title': 'Pilot',
      'missing_subtitles': [],
    });

    expect(item.isMovie, isFalse);
    expect(item.seriesId, 10);
    expect(item.episodeId, 20);
    expect(item.missingLanguages, isEmpty);
  });

  test('falls back to plain seriesId/episodeId keys', () {
    final item = BazarrWantedItem.fromJson({
      'seriesId': 5,
      'episodeId': 6,
      'title': 'Pilot',
    });

    expect(item.seriesId, 5);
    expect(item.episodeId, 6);
  });

  test('defaults title to Unknown when missing', () {
    final item = BazarrWantedItem.fromJson({});
    expect(item.title, 'Unknown');
  });
}
