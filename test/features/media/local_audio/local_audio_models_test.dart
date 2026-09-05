import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/local_audio/domain/local_audio_models.dart';

Map<String, Object?> audioSnapshot({bool playing = false}) => {
  'supported': true,
  'phase': 'ready',
  'sourceId': 'station-one',
  'title': 'Station',
  'artist': 'Artist',
  'album': 'Album',
  'isPlaying': playing,
  'positionMs': 1200,
  'durationMs': null,
  'canPlay': !playing,
  'canPause': playing,
  'canSeek': false,
  'canStop': true,
  'failure': null,
};
LocalAudioSource audioSource() => LocalAudioSource(
  id: 'station-one',
  uri: Uri.parse('https://radio.example/audio.mp3'),
  mimeType: 'audio/mpeg',
  title: 'Station',
  artist: 'Artist',
  album: 'Album',
);
Matcher audioFailure(LocalAudioFailure failure) => isA<LocalAudioException>()
    .having((error) => error.failure, 'failure', failure);

void main() {
  test(
    'source rejects authenticated, unsafe and non-audio transport shapes',
    () {
      for (final uri in [
        'https://user:secret@host/audio.mp3',
        'file:///private/audio.mp3',
        'content://media/1',
        'ftp://host/audio.mp3',
        'https://host/audio?token=secret',
        'https://host/audio?',
        'https://host/audio#token',
        'https://host:0/audio',
        'https://host:65536/audio',
        'https://host/audio%0d%0aCookie:secret',
      ]) {
        expect(
          () => LocalAudioSource(
            id: 'one',
            uri: Uri.parse(uri),
            mimeType: 'audio/mpeg',
            title: 'Station',
          ),
          throwsA(audioFailure(LocalAudioFailure.invalidSource)),
        );
      }
      for (final mime in [
        'video/mp4',
        'application/x-mpegURL',
        'audio/mpeg;secret',
        'text/html',
      ]) {
        expect(
          () => LocalAudioSource(
            id: 'one',
            uri: Uri.parse('https://host/audio'),
            mimeType: mime,
            title: 'Station',
          ),
          throwsA(audioFailure(LocalAudioFailure.invalidSource)),
        );
      }
      expect(
        () => LocalAudioSource(
          id: 'https://secret',
          uri: Uri.parse('https://host/audio'),
          mimeType: 'audio/mpeg',
          title: 'Station',
        ),
        throwsA(audioFailure(LocalAudioFailure.invalidSource)),
      );
      expect(
        () => LocalAudioSource(
          id: 'one',
          uri: Uri.parse('https://host/audio'),
          mimeType: 'audio/mpeg',
          title: 'x' * 257,
        ),
        throwsA(audioFailure(LocalAudioFailure.invalidSource)),
      );
      expect(audioSource().toString(), isNot(contains('radio.example')));
      expect(
        audioSource().toChannel()['uri'],
        'https://radio.example/audio.mp3',
      );
      expect(
        LocalAudioSource.mimeTypes,
        containsAll(['audio/mpeg', 'audio/ogg', 'audio/flac']),
      );
    },
  );

  test(
    'unknown stream duration remains unknown and live stream is not seekable',
    () {
      final state = LocalAudioSnapshot.fromChannel(
        audioSnapshot(playing: true),
      );
      expect(state.duration, isNull);
      expect(state.position, const Duration(milliseconds: 1200));
      expect(state.isPlaying, isTrue);
      expect(state.canSeek, isFalse);
      expect(state.canPause, isTrue);
      expect(state.canPlay, isFalse);
    },
  );

  test(
    'strict native snapshots reject impossible or credential-bearing state',
    () {
      for (final mutation in [
        {'positionMs': double.nan},
        {'durationMs': -1},
        {'durationMs': 0},
        {'positionMs': 1.5},
        {'positionMs': 2592000001},
        {'sourceId': '../private'},
        {'canSeek': true},
        {'phase': 'unknown'},
        {'title': 'header\ninjection'},
        {'uri': 'https://private.example/key'},
        {
          'headers': {'Authorization': 'secret'},
        },
        {'isPlaying': true, 'sourceId': null},
        {'isPlaying': true, 'phase': 'loading'},
        {'failure': 'private exception detail'},
        {'canPlay': 'true'},
      ]) {
        expect(
          () =>
              LocalAudioSnapshot.fromChannel({...audioSnapshot(), ...mutation}),
          throwsA(audioFailure(LocalAudioFailure.invalidResponse)),
        );
      }
    },
  );

  test(
    'unsupported power is unknown; notification exemption is not permission',
    () {
      final unsupported = LocalAudioPowerStatus.fromChannel({
        'supported': false,
      });
      expect(unsupported.batteryOptimizationExempt, isNull);
      expect(unsupported.notificationsEnabled, isNull);
      final actual = LocalAudioPowerStatus.fromChannel({
        'supported': true,
        'sdkInt': 36,
        'notificationsEnabled': false,
        'notificationPermissionGranted': false,
        'mediaNotificationExempt': true,
        'batteryOptimizationExempt': false,
        'backgroundRestricted': true,
      });
      expect(actual.mediaNotificationExempt, isTrue);
      expect(actual.notificationPermissionGranted, isFalse);
      expect(actual.backgroundRestricted, isTrue);
    },
  );
}
