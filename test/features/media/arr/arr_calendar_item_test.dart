import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/arr/data/models/arr_calendar_item.dart';

void main() {
  test('parses a Sonarr episode entry with a series title and S/E code', () {
    final item = ArrCalendarItem.fromJson({
      'title': 'Pilot',
      'series': {'title': 'Breaking Bad'},
      'seasonNumber': 1,
      'episodeNumber': 2,
      'airDateUtc': '2026-09-01T00:00:00Z',
      'hasFile': true,
    });

    expect(item.title, 'Breaking Bad');
    expect(item.subtitle, 'S01E02 Pilot');
    expect(item.date, DateTime.parse('2026-09-01T00:00:00Z'));
    expect(item.hasFile, isTrue);
  });

  test('parses a Radarr movie entry with no series/subtitle', () {
    final item = ArrCalendarItem.fromJson({
      'title': 'The Matrix',
      'inCinemas': '2026-09-05T00:00:00Z',
    });

    expect(item.title, 'The Matrix');
    expect(item.subtitle, isNull);
    expect(item.date, DateTime.parse('2026-09-05T00:00:00Z'));
    expect(item.hasFile, isFalse);
  });

  test('date falls back through airDateUtc > inCinemas > digitalRelease > physicalRelease', () {
    final digital = ArrCalendarItem.fromJson({
      'title': 'X',
      'digitalRelease': '2026-09-10T00:00:00Z',
      'physicalRelease': '2026-09-20T00:00:00Z',
    });
    expect(digital.date, DateTime.parse('2026-09-10T00:00:00Z'));

    final physical = ArrCalendarItem.fromJson({
      'title': 'X',
      'physicalRelease': '2026-09-20T00:00:00Z',
    });
    expect(physical.date, DateTime.parse('2026-09-20T00:00:00Z'));

    final none = ArrCalendarItem.fromJson({'title': 'X'});
    expect(none.date, isNull);
  });

  test('parses a Lidarr album entry with a nested artist.artistName', () {
    final item = ArrCalendarItem.fromJson({
      'title': 'OK Computer',
      'artist': {'artistName': 'Radiohead'},
      'releaseDate': '2026-09-01T00:00:00Z',
    });

    expect(item.title, 'Radiohead');
    expect(item.subtitle, 'OK Computer');
    expect(item.date, DateTime.parse('2026-09-01T00:00:00Z'));
  });

  test('parses a Readarr book entry with a nested author.authorName', () {
    final item = ArrCalendarItem.fromJson({
      'title': 'Some Book',
      'author': {'authorName': 'Some Author'},
    });

    expect(item.title, 'Some Author');
    expect(item.subtitle, 'Some Book');
  });
}
