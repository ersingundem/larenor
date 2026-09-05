import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/casting/domain/remote_playback_models.dart';

import 'remote_playback_fixture.dart';

void main() {
  test('safe opaque session IDs are distinct from canonical item GUIDs', () {
    expect(remoteSessionId('remote_session-1'), 'remote_session-1');
    expect(remoteItemId('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA'), itemId);
    for (final value in ['../other', 'a/b', 'a?token=x', 'a%2fb', '']) {
      expect(
        () => remoteSessionId(value),
        throwsA(isA<RemotePlaybackException>()),
      );
    }
    expect(
      () => remoteItemId('movie123'),
      throwsA(isA<RemotePlaybackException>()),
    );
  });
  test('same-user receiver requires explicit capabilities, video, active and nonlocal stable identity', () {
    expect(
      target().eligibleFor(userId: userId, localDeviceId: 'local-tablet'),
      isTrue,
    );
    final variants = <Map<String, dynamic>>[
      targetJson(user: otherUserId),
      targetJson(device: 'local-tablet'),
      targetJson()..remove('ServerId'),
      targetJson()..remove('DeviceId'),
      targetJson()..remove('UserId'),
      targetJson()..remove('IsActive'),
      targetJson()..remove('SupportsRemoteControl'),
      targetJson()..remove('SupportsMediaControl'),
      targetJson()..['PlayableMediaTypes'] = ['Audio'],
    ];
    for (final json in variants) {
      expect(
        parseRemotePlaybackTargets([json]).single
            .eligibleFor(userId: userId, localDeviceId: 'local-tablet'),
        isFalse,
      );
    }
    expect(target(server: 'second').sameIdentity(target()), isFalse);
    expect(target(device: 'second').sameIdentity(target()), isFalse);
  });
  test('null playback values remain unknown and stale item identity does not imply playback', () {
    final value = parseRemotePlaybackTargets([targetJson()..['PlayState'] = {}])
        .single;
    expect(value.isPaused, isNull);
    expect(value.positionTicks, isNull);
    expect(value.nowPlayingItemId, isNull);
  });
  test('bounded typed parser rejects duplicate IDs, unsafe fields and nonfinite or negative positions', () {
    for (final invalid in [
      [targetJson(), targetJson()],
      List.generate(257, (i) => targetJson(id: 's$i')),
      [targetJson()..['SupportsRemoteControl'] = 'true'],
      [targetJson()..['DeviceName'] = 'private\nheader'],
      [
        targetJson()..['PlayState'] = {'PositionTicks': -1},
      ],
      [
        targetJson()..['PlayState'] = {'PositionTicks': double.nan},
      ],
      [
        targetJson()..['PlayState'] = {'PositionTicks': 1.5},
      ],
      [targetJson()..['LastPlaybackCheckIn'] = '2026-09-05T00:00:00'],
    ]) {
      expect(
        () => parseRemotePlaybackTargets(invalid),
        throwsA(isA<RemotePlaybackException>()),
      );
    }
    final targets = parseRemotePlaybackTargets([
      targetJson(id: 'z'),
      targetJson(id: 'a'),
    ]);
    expect(targets.map((value) => value.sessionId), ['a', 'z']);
    expect(() => targets.add(target()), throwsUnsupportedError);
  });
}
