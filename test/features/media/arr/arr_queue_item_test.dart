import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/media/arr/data/models/arr_queue_item.dart';

void main() {
  test('computes progressFraction from size and sizeleft', () {
    final item = ArrQueueItem.fromJson({
      'id': 1,
      'title': 'Episode 1',
      'status': 'downloading',
      'size': 1000,
      'sizeleft': 250,
      'timeleft': '00:05:00',
    });

    expect(item.progressFraction, 0.75);
    expect(item.timeLeft, '00:05:00');
  });

  test('progressFraction is null when size is missing or zero', () {
    final noSize = ArrQueueItem.fromJson({
      'id': 1,
      'title': 'x',
      'status': 'downloading',
      'sizeleft': 250,
    });
    expect(noSize.progressFraction, isNull);

    final zeroSize = ArrQueueItem.fromJson({
      'id': 1,
      'title': 'x',
      'status': 'downloading',
      'size': 0,
      'sizeleft': 0,
    });
    expect(zeroSize.progressFraction, isNull);
  });

  test('falls back to nested series/movie title when title is absent', () {
    final fromSeries = ArrQueueItem.fromJson({
      'id': 1,
      'status': 'downloading',
      'series': {'title': 'Breaking Bad'},
    });
    expect(fromSeries.title, 'Breaking Bad');

    final fromMovie = ArrQueueItem.fromJson({
      'id': 1,
      'status': 'downloading',
      'movie': {'title': 'The Matrix'},
    });
    expect(fromMovie.title, 'The Matrix');
  });

  test('defaults to Unknown title and unknown status', () {
    final item = ArrQueueItem.fromJson({});
    expect(item.title, 'Unknown');
    expect(item.status, 'unknown');
  });
}
