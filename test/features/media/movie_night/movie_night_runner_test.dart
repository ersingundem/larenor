import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/media/movie_night/data/movie_night_store.dart';
import 'package:larenor/features/media/movie_night/domain/movie_night_preset.dart';
import 'package:larenor/features/media/movie_night/domain/movie_night_runner.dart';

const preset = MovieNightPreset(
  serverUrl: 'https://ha.test/proxy',
  startEntityId: 'scene.cinema',
  finishEntityId: 'script.lights_up',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('scene ACK precedes player; finishing scene is a separate single-use action', () async {
    final operations = <String>[];
    final ack = Completer<void>();
    final runner = MovieNightRunner(
      preset: preset,
      isCurrent: () => true,
      activate: (id) async {
        operations.add(id);
        if (id == preset.startEntityId) await ack.future;
      },
      play: () async {
        operations.add('player');
        return true;
      },
    );
    final running = runner.run();
    expect(operations, ['scene.cinema']);
    expect(await runner.run(), MovieNightOutcome.alreadyStarted);
    expect(await runner.finish(), isFalse);
    ack.complete();
    expect(await running, MovieNightOutcome.finished);
    expect(operations, ['scene.cinema', 'player']);
    expect(await runner.finish(), isTrue);
    expect(await runner.finish(), isFalse);
    expect(operations, ['scene.cinema', 'player', 'script.lights_up']);
  });

  test('uncertain scene result causes no playback, retry or undo', () async {
    var sends = 0;
    final runner = MovieNightRunner(
      preset: preset,
      isCurrent: () => true,
      activate: (_) async {
        sends++;
        throw TimeoutException('fixture');
      },
      play: () async => throw StateError('Player must not start'),
    );
    expect(await runner.run(), MovieNightOutcome.sceneFailed);
    expect(await runner.run(), MovieNightOutcome.alreadyStarted);
    expect(await runner.finish(), isFalse);
    expect(sends, 1);
  });

  test(
    'account/lifecycle change while scene is pending blocks the player',
    () async {
      var current = true;
      final ack = Completer<void>();
      final runner = MovieNightRunner(
        preset: preset,
        isCurrent: () => current,
        activate: (_) => ack.future,
        play: () async => throw StateError('Expired player callback'),
      );
      final running = runner.run();
      current = false;
      ack.complete();
      expect(await running, MovieNightOutcome.cancelled);
      expect(runner.canFinish, isFalse);
    },
  );

  test('playback failure preserves explicit finish choice but never auto-executes it', () async {
    final operations = <String>[];
    final runner = MovieNightRunner(
      preset: preset,
      isCurrent: () => true,
      activate: (id) async {
        operations.add(id);
      },
      play: () async => throw StateError('Player failed'),
    );
    expect(await runner.run(), MovieNightOutcome.playbackFailed);
    expect(operations, ['scene.cinema']);
    expect(await runner.finish(), isTrue);
    expect(operations, ['scene.cinema', 'script.lights_up']);
  });

  test('expired finishing confirmation sends nothing', () async {
    var current = true;
    final operations = <String>[];
    final runner = MovieNightRunner(
      preset: preset,
      isCurrent: () => current,
      activate: (id) async {
        operations.add(id);
      },
      play: () async => true,
    );
    await runner.run();
    current = false;
    expect(await runner.finish(), isFalse);
    expect(operations, ['scene.cinema']);
  });

  test('no finishing scene is invented', () async {
    final runner = MovieNightRunner(
      preset: const MovieNightPreset(
        serverUrl: 'https://ha.test',
        startEntityId: 'scene.cinema',
      ),
      isCurrent: () => true,
      activate: (_) async {},
      play: () async => true,
    );
    await runner.run();
    expect(runner.canFinish, isFalse);
    expect(await runner.finish(), isFalse);
  });

  test('strict stored settings reject arbitrary actions, URLs and fields', () {
    expect(
      MovieNightPreset.decodeStored(preset.encodeStored()).startEntityId,
      'scene.cinema',
    );
    for (final override in [
      {'startEntityId': 'lock.front'},
      {'finishEntityId': 'scene.cinema\n'},
      {'serverUrl': 'https://user:secret@ha.test'},
      {'version': 2},
      {
        'serviceData': {'entity_id': 'all'},
      },
    ]) {
      expect(
        () => MovieNightPreset.decodeStored(
          jsonEncode({...preset.toJson(), ...override}),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => MovieNightPreset.decodeStored('x' * 16385),
      throwsFormatException,
    );
  });

  test('queued preference write rechecks account before persisting', () async {
    SharedPreferences.setMockInitialValues({});
    final gate = Completer<void>();
    final blocking = ConfigurationWrites.run(() => gate.future);
    var current = true;
    final store = MovieNightStore();
    final saving = store.save(preset, isCurrent: () => current);
    final expectation = expectLater(saving, throwsStateError);
    current = false;
    gate.complete();
    await blocking;
    await expectation;
    expect(await store.read(), isNull);
    await store.save(preset, isCurrent: () => true);
    expect((await store.read())?.finishEntityId, 'script.lights_up');
  });
}
