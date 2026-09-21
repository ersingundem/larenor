import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_track_preferences_store.dart';
import 'package:larenor/features/media/jellyfin/domain/jellyfin_track_preferences.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _first = JellyfinConfig(
  baseUrl: 'https://first.example',
  userId: 'person-one',
  accessToken: 'never-persist-this-token',
  deviceId: 'tablet',
);
const _second = JellyfinConfig(
  baseUrl: 'https://first.example',
  userId: 'person-two',
  accessToken: 'another-token',
  deviceId: 'tablet',
);

void main() {
  test('matches only present, supported language tracks', () {
    const audio = [
      AudioTrack('1', 'English', 'en'),
      AudioTrack('2', 'Turkish', 'tr-TR'),
      AudioTrack('3', 'Unknown', null),
    ];
    const subtitles = [
      SubtitleTrack('4', 'English', 'en'),
      SubtitleTrack('5', 'Turkish', 'tr'),
    ];
    expect(JellyfinTrackPreferences.audio(audio, 'tr')?.id, '2');
    expect(JellyfinTrackPreferences.subtitle(subtitles, 'tr-TR')?.id, '5');
    expect(JellyfinTrackPreferences.audio(audio, 'de'), isNull);
    expect(JellyfinTrackPreferences.subtitle(subtitles, 'de'), isNull);
    expect(JellyfinTrackPreferences.subtitle(subtitles, 'off')?.id, 'no');
    expect(JellyfinTrackPreferences.audio(audio, 'no'), isNull);
  });

  test('preference record is bounded and isolated by Jellyfin account', () async {
    SharedPreferences.setMockInitialValues({});
    final store = JellyfinTrackPreferencesStore();
    await store.save(_first, audioLanguage: 'tr-TR', subtitleLanguage: 'off',
        isCurrent: () => true);
    expect((await store.read(_first, isCurrent: () => true))?.audioLanguage, 'tr-tr');
    expect((await store.read(_first, isCurrent: () => true))?.subtitleLanguage, 'off');
    expect(await store.read(_second, isCurrent: () => true), isNull);
    final raw = (await SharedPreferences.getInstance()).getKeys().join(' ');
    expect(raw, isNot(contains(_first.accessToken)));
    expect(raw, isNot(contains(_first.userId)));
    await expectLater(
      store.save(_first, audioLanguage: 'not-a-valid-language-tag',
          subtitleLanguage: null, isCurrent: () => true),
      throwsFormatException,
    );
  });

  test('expired route refuses a preference write or read', () async {
    SharedPreferences.setMockInitialValues({});
    final store = JellyfinTrackPreferencesStore();
    await expectLater(store.save(_first, audioLanguage: 'en',
        subtitleLanguage: null, isCurrent: () => false), throwsStateError);
    await expectLater(store.read(_first, isCurrent: () => false), throwsStateError);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });
}
