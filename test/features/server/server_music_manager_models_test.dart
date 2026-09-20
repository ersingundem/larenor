import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';

import 'server_music_manager_test_support.dart';

void main() {
  test(
    'manager parses one secret-free provider, queue and receiver surface',
    () {
      final manager = ServerMusicManager.fromJson(musicManagerJson());

      expect(manager.providers.single.domain, 'spotify');
    expect(manager.receivers.map((item) => item.kind), [
      'homepod',
      'cast',
      'airplay',
    ]);
      expect(manager.queueFor(manager.receivers.first)?.itemCount, 1);
      expect(
        manager.receivers.first.supports(ServerMusicOperation.queueAdd),
        true,
      );
    },
  );

  test('manager rejects secret, duplicate and incoherent public readbacks', () {
    final original = musicManagerJson();
    final receiver = Map<String, dynamic>.from(
      (original['receivers'] as List).first as Map<String, dynamic>,
    );
    for (final value in [
      {...original, 'token': 'must-not-be-public'},
      {
        ...original,
        'receivers': [receiver, receiver],
      },
      {
        ...original,
        'receivers': [
          {
            ...receiver,
            'groupMembers': ['missing-player'],
          },
        ],
      },
    ]) {
      expect(
        () => ServerMusicManager.fromJson(value),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });
}
