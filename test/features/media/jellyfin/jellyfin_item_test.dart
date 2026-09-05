import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';

void main() {
  test('resume starts from server ticks but completed items start over', () {
    const item = JellyfinItem(
      id: 'one',
      name: 'Film',
      type: 'Movie',
      runTimeTicks: 12000000000,
      userData: JellyfinUserData(playbackPositionTicks: 600000000),
    );
    expect(item.resumePosition, const Duration(seconds: 60));
    expect(
      item
          .copyWith(
            userData: const JellyfinUserData(
              playbackPositionTicks: 600000000,
              played: true,
            ),
          )
          .resumePosition,
      Duration.zero,
    );
  });

  test('derives resume progress when Jellyfin omits PlayedPercentage', () {
    final item = JellyfinItem.fromJson({
      'Id': 'episode',
      'Name': 'Pilot',
      'Type': 'Episode',
      'RunTimeTicks': 1000,
      'UserData': {'PlaybackPositionTicks': 250},
    });
    expect(item.playedFraction, 0.25);
  });

  test('parses PascalCase Jellyfin fields', () {
    final item = JellyfinItem.fromJson({
      'Id': 'abc123',
      'Name': 'The Matrix',
      'Type': 'Movie',
      'Overview': 'A hacker discovers reality is a simulation.',
      'ProductionYear': 1999,
      'UserData': {'PlaybackPositionTicks': 0, 'PlayedPercentage': 45.5},
    });

    expect(item.id, 'abc123');
    expect(item.name, 'The Matrix');
    expect(item.type, 'Movie');
    expect(item.productionYear, 1999);
    expect(item.userData?.playedPercentage, 45.5);
  });

  test('isPlayable requires positive media and user access evidence', () {
    JellyfinItem itemOfType(String type) => JellyfinItem.fromJson({
      'Id': '1',
      'Name': 'x',
      'Type': type,
      'LocationType': 'FileSystem',
      'PlayAccess': 'Full',
    });

    expect(itemOfType('Movie').isPlayable, isTrue);
    expect(itemOfType('Episode').isPlayable, isTrue);
    expect(itemOfType('Series').isPlayable, isFalse);
    expect(itemOfType('CollectionFolder').isPlayable, isFalse);
  });

  test('metadata-only movies and episodes remain unknown, never playable', () {
    for (final type in ['Movie', 'Episode']) {
      final item = JellyfinItem.fromJson({
        'Id': 'item',
        'Name': 'Fixture',
        'Type': type,
      });
      expect(item.isPlayable, isFalse);
      expect(item.playbackEligibility, JellyfinPlaybackEligibility.unknown);
      expect(
        item.copyWith(locationType: 'FileSystem').playbackEligibility,
        JellyfinPlaybackEligibility.unknown,
      );
      expect(
        item.copyWith(playAccess: 'Full').playbackEligibility,
        JellyfinPlaybackEligibility.unknown,
      );
      expect(
        item
            .copyWith(locationType: 'UnknownFutureType', playAccess: 'Full')
            .isPlayable,
        isFalse,
      );
    }
  });

  test('missing, virtual, offline, denied or zero-source metadata cannot be playable', () {
    const base = JellyfinItem(
      id: 'episode',
      name: 'Fixture',
      type: 'Episode',
      locationType: 'FileSystem',
      playAccess: 'Full',
    );
    expect(base.isPlayable, isTrue); // Count one is omitted by Jellyfin DTO.
    for (final item in [
      base.copyWith(isMissing: true),
      base.copyWith(isVirtualItem: true),
      base.copyWith(locationType: 'Virtual'),
      base.copyWith(locationType: 'Offline'),
      base.copyWith(playAccess: 'None'),
      base.copyWith(mediaSourceCount: 0),
      base.copyWith(mediaSourceCount: -1),
    ]) {
      expect(item.isPlayable, isFalse);
      expect(item.playbackEligibility, JellyfinPlaybackEligibility.unavailable);
    }
    expect(
      base.copyWith(locationType: 'Remote', mediaSourceCount: 2).isPlayable,
      isTrue,
    );
    expect(
      base.copyWith(type: 'Series', mediaSourceCount: 10).playbackEligibility,
      JellyfinPlaybackEligibility.container,
    );
  });

  test('parses compatibility flags, premiere instant, and season zero without inventing readiness', () {
    final item = JellyfinItem.fromJson({
      'Id': 'special',
      'Name': 'Special',
      'Type': 'Episode',
      'IndexNumber': 0,
      'ParentIndexNumber': 0,
      'IsMissing': true,
      'IsVirtualItem': true,
      'LocationType': 'Virtual',
      'PlayAccess': 'Full',
      'MediaSourceCount': 0,
      'PremiereDate': '2026-10-01T12:00:00Z',
    });
    expect(item.parentIndexNumber, 0);
    expect(item.indexNumber, 0);
    expect(item.isMissing, isTrue);
    expect(item.isVirtualItem, isTrue);
    expect(item.isVirtual, isTrue);
    expect(item.premiereDate, DateTime.utc(2026, 10, 1, 12));
    expect(JellyfinItem.fromJson(item.toJson()), item);
    expect(item.isPlayable, isFalse);
  });

  test('playedFraction converts percentage to a 0..1 fraction', () {
    final item = JellyfinItem.fromJson({
      'Id': '1',
      'Name': 'x',
      'Type': 'Movie',
      'UserData': {'PlayedPercentage': 50.0},
    });
    expect(item.playedFraction, 0.5);
  });

  test('playedFraction is 0 when there is no UserData', () {
    final item = JellyfinItem.fromJson({
      'Id': '1',
      'Name': 'x',
      'Type': 'Movie',
    });
    expect(item.playedFraction, 0);
  });
}
