import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_media_inventory.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_playback_models.dart';

import 'ha_playback_fixture.dart';

void main() {
  test(
    'browse preserves MIME, no URL/artwork or arbitrary metadata in model',
    () {
      final page = parseHaMediaBrowse({
        ...browseRaw(),
        'thumbnail': 'https://secret.invalid/?token=fixture',
      }, playbackNow);
      expect(page.children.single.mediaType, 'audio/mpeg');
      expect(page.children.single.playable, isTrue);
      expect(() => page.children.clear(), throwsUnsupportedError);
    },
  );
  for (final id in [
    'https://host.invalid/file?token=fixture',
    'media-source://foo/x?token=fixture',
    'media-source://foo/x%3Ftoken=fixture',
    'media-source://foo/x\\evil',
    'media-source://foo/x\n',
    'media-source://foo//x',
  ]) {
    test('reject unsupported source identity $id', () {
      expect(
        () => parseHaMediaBrowse(
          browseRaw(children: [browseNode(id: id)]),
          playbackNow,
        ),
        throwsA(isA<HaPlaybackException>()),
      );
    });
  }
  test('URL/app/generic music types are not guessed as MIME', () {
    for (final type in [
      'url',
      'app',
      'music',
      'audio/*',
      'audio/mpeg; token=fixture',
    ]) {
      expect(
        parseHaMediaBrowse(
          browseRaw(children: [browseNode(type: type)]),
          playbackNow,
        ).children.single.playable,
        isFalse,
      );
    }
  });
  test('duplicate, malformed, oversized and unknown child results reject', () {
    for (final raw in [
      browseRaw(children: [browseNode(), browseNode()]),
      {...browseRaw(), 'children': null},
      browseRaw(
        children: [
          {...browseNode(), 'can_play': 'true'},
        ],
      ),
      {...browseRaw(), 'not_shown': -1},
      browseRaw(children: List.filled(5001, browseNode())),
    ]) {
      expect(
        () => parseHaMediaBrowse(raw, playbackNow),
        throwsA(isA<HaPlaybackException>()),
      );
    }
  });
  test('empty is valid and partial omitted count remains visible', () {
    final page = parseHaMediaBrowse({
      ...browseRaw(children: []),
      'not_shown': 3,
    }, playbackNow);
    expect(page.children, isEmpty);
    expect(page.notShown, 3);
  });
  test(
    'target registry capability and MIME determine conservative eligibility',
    () {
      final audio = parseHaMediaBrowse(
        browseRaw(),
        playbackNow,
      ).children.single;
      final video = parseHaMediaBrowse(
        browseRaw(children: [browseNode(type: 'video/mp4')]),
        playbackNow,
      ).children.single;
      final speaker = inventory();
      expect(speaker.targets.single.canPlay(audio, speaker), isTrue);
      expect(speaker.targets.single.canPlay(video, speaker), isFalse);
      final tv = inventory(state: stateRaw(deviceClass: 'tv'));
      expect(tv.targets.single.receiverKind, HaMediaReceiverKind.castDisplay);
      expect(tv.targets.single.canPlay(video, tv), isTrue);
      final apple = inventory(
        state: stateRaw(deviceClass: 'tv'),
        registry: registryRaw(platform: 'apple_tv'),
      );
      expect(apple.targets.single.canPlay(audio, apple), isTrue);
      expect(apple.targets.single.canPlay(video, apple), isFalse);
      for (final blocked in [
        inventory(state: stateRaw(features: 0)),
        inventory(state: stateRaw(state: 'unavailable')),
        inventory(registry: {...registryRaw(), 'disabled_by': 'user'}),
        inventory(services: {}),
      ]) {
        expect(blocked.targets.single.canPlay(audio, blocked), isFalse);
      }
    },
  );
  test('missing registry is read issue not installed-device absence or mutation authority', () {
    final value = parseHaMediaInventory(
      states: [stateRaw()],
      services: mediaServices,
      registry: null,
      readAt: playbackNow,
      registryFailure: HaPlaybackFailure.permission,
    );
    expect(value.targets, hasLength(1));
    expect(value.registryAvailable, isFalse);
    expect(value.registryFailure, HaPlaybackFailure.permission);
    expect(
      value.targets.single.canPlay(
        parseHaMediaBrowse(browseRaw(), playbackNow).children.single,
        value,
      ),
      isFalse,
    );
  });
  test(
    'receiver identity does not derive from name and secret URLs omitted',
    () {
      final value = inventory(
        state: stateRaw(contentId: 'https://host.invalid/?api_key=fixture'),
      );
      expect(value.targets.single.mediaContentId, isNull);
      final other = inventory(registry: registryRaw(registry: 'other'));
      expect(value.targets.single.sameIdentity(other.targets.single), isFalse);
    },
  );
  test(
    'legacy published service schema also accepted; descriptors immutable',
    () {
      final value = inventory(
        services: {
          'media_player': {
            'play_media': {
              'fields': {'media_content_id': {}, 'media_content_type': {}},
            },
          },
        },
      );
      expect(value.hasPlayMedia, isTrue);
      expect(
        () => ((value.services['media_player'] as Map)['play_media'] as Map)
            .clear(),
        throwsUnsupportedError,
      );
    },
  );
  test('malformed states and registry fail closed', () {
    for (final state in [
      {...stateRaw(), 'attributes': null},
      stateRaw(features: -1),
      {...stateRaw(), 'last_updated': '2026-09-05'},
      {...stateRaw(), 'state': true},
    ]) {
      expect(
        () => inventory(state: state),
        throwsA(isA<HaPlaybackException>()),
      );
    }
    expect(
      () => parseHaMediaInventory(
        states: [stateRaw()],
        services: mediaServices,
        registry: [registryRaw(), registryRaw()],
        readAt: playbackNow,
      ),
      throwsA(isA<HaPlaybackException>()),
    );
  });
  test(
    'now playing metadata is bounded nullable and finite, never playback proof',
    () {
      final row = stateRaw();
      (row['attributes'] as Map).addAll(<String, dynamic>{
        'media_title': 'Song',
        'media_artist': 'Artist',
        'media_album_name': 'Album',
        'media_duration': 120,
        'media_position': 12.5,
        'volume_level': 0.4,
        'is_volume_muted': false,
      });
      final target = inventory(state: row).targets.single;
      expect(target.mediaTitle, 'Song');
      expect(target.durationSeconds, 120);
      expect(target.positionSeconds, 12.5);
      expect(target.volumeLevel, 0.4);
      expect(target.isVolumeMuted, isFalse);
      expect(target.mediaContentId, isNull);
      expect(inventory().targets.single.durationSeconds, isNull);
      for (final invalid in [
        {'volume_level': 1.1},
        {'media_position': double.nan},
        {'media_duration': -1},
        {'is_volume_muted': 'false'},
      ]) {
        final malformed = stateRaw();
        (malformed['attributes'] as Map).addAll(invalid);
        expect(
          () => inventory(state: malformed),
          throwsA(isA<HaPlaybackException>()),
        );
      }
    },
  );
  test('opaque source filenames allow spaces but never nested URLs or encoded credentials', () {
    expect(
      haMediaSourceId('media-source://media_source/local/My song.mp3'),
      contains('My song'),
    );
    for (final source in [
      'media-source://x/https://user@host/file',
      'media-source://x/https%3A%2F%2Fhost',
      'media-source://x/a%253Ftoken',
      'media-source://x/a%40host',
    ]) {
      expect(
        () => haMediaSourceId(source),
        throwsA(isA<HaPlaybackException>()),
      );
    }
  });
}
