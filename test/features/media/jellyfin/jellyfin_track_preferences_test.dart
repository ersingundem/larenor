import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/domain/jellyfin_track_preferences.dart';
import 'package:media_kit/media_kit.dart';

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
    expect(
      JellyfinTrackPreferences.audio(const [
        AudioTrack('8', 'English (ISO 639-2)', 'eng'),
      ], 'en')?.id,
      '8',
    );
    expect(
      JellyfinTrackPreferences.subtitle(const [
        SubtitleTrack('9', 'Turkish (ISO 639-2)', 'tur'),
      ], 'tr')?.id,
      '9',
    );
    expect(
      JellyfinTrackPreferences.audio(const [
        AudioTrack('6', 'Cyprus Turkish', 'tr-CY'),
        AudioTrack('7', 'Turkey Turkish', 'tr-TR'),
      ], 'tr-TR')?.id,
      '7',
    );
    expect(JellyfinTrackPreferences.subtitle(subtitles, 'tr-TR')?.id, '5');
    expect(JellyfinTrackPreferences.audio(audio, 'de'), isNull);
    expect(JellyfinTrackPreferences.subtitle(subtitles, 'de'), isNull);
    expect(JellyfinTrackPreferences.subtitle(subtitles, 'off')?.id, 'no');
    expect(JellyfinTrackPreferences.audio(audio, 'no'), isNull);
  });
}
