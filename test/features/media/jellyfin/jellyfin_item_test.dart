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

  test('isPlayable is true for Movie and Episode only', () {
    JellyfinItem itemOfType(String type) =>
        JellyfinItem.fromJson({'Id': '1', 'Name': 'x', 'Type': type});

    expect(itemOfType('Movie').isPlayable, isTrue);
    expect(itemOfType('Episode').isPlayable, isTrue);
    expect(itemOfType('Series').isPlayable, isFalse);
    expect(itemOfType('CollectionFolder').isPlayable, isFalse);
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
