import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/media/movie_night/data/movie_night_store.dart';
import 'package:larenor/features/media/movie_night/domain/movie_night_preset.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _preset = MovieNightPreset(
  serverUrl: 'https://ha.test',
  startEntityId: 'scene.cinema',
  finishEntityId: 'script.lights_up',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('record binds exact server scope and typed resource envelope', () async {
    SharedPreferences.setMockInitialValues({});
    final now = DateTime.utc(2026, 9, 23, 10);
    final store = MovieNightStore(now: () => now);

    await store.save(_preset, isCurrent: () => true);

    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(MovieNightPreset.storageKey)!;
    final record = jsonDecode(raw) as Map<String, dynamic>;
    expect(record.keys, {
      'schemaVersion',
      'scope',
      'resource',
      'savedAt',
      'preset',
    });
    expect(record['schemaVersion'], 1);
    expect(record['scope'], {'serverUrl': 'https://ha.test'});
    expect(record['resource'], {'kind': 'movie_night_preset', 'revision': 1});
    expect(raw, isNot(contains('token')));
    expect(
      (await store.read(
        serverUrl: 'https://ha.test',
        isCurrent: () => true,
      ))?.startEntityId,
      'scene.cinema',
    );
    expect(
      await store.read(serverUrl: 'https://other.test', isCurrent: () => true),
      isNull,
    );
    expect(preferences.getString(MovieNightPreset.storageKey), raw);

    const noFinish = MovieNightPreset(
      serverUrl: 'https://ha.test',
      startEntityId: 'scene.quiet',
    );
    await store.save(noFinish, isCurrent: () => true);
    expect(
      (await store.read(
        serverUrl: noFinish.serverUrl,
        isCurrent: () => true,
      ))?.finishEntityId,
      isNull,
    );
  });

  test(
    'schema TTL and byte quota fail closed and clear exact record',
    () async {
      SharedPreferences.setMockInitialValues({});
      var now = DateTime.utc(2026, 9, 23, 10);
    final store = MovieNightStore(now: () => now);
    await store.save(_preset, isCurrent: () => true);
    final preferences = await SharedPreferences.getInstance();

    final wrongSchema =
        jsonDecode(preferences.getString(MovieNightPreset.storageKey)!)
            as Map<String, dynamic>;
    wrongSchema['schemaVersion'] = 2;
    await preferences.setString(
      MovieNightPreset.storageKey,
      jsonEncode(wrongSchema),
    );
    expect(
      await store.read(serverUrl: _preset.serverUrl, isCurrent: () => true),
      isNull,
    );
    expect(preferences.getString(MovieNightPreset.storageKey), isNull);

    await store.save(_preset, isCurrent: () => true);
    now = now.add(MovieNightStore.timeToLive);
      expect(
        await store.read(serverUrl: _preset.serverUrl, isCurrent: () => true),
        isNull,
      );
      expect(preferences.getString(MovieNightPreset.storageKey), isNull);

      await preferences.setString(
        MovieNightPreset.storageKey,
        'x' * (MovieNightStore.maximumBytes + 1),
      );
      expect(
        await store.read(serverUrl: _preset.serverUrl, isCurrent: () => true),
        isNull,
      );
      expect(preferences.getString(MovieNightPreset.storageKey), isNull);
    },
  );

  test('retired lifecycle cannot consume a queued persistent read', () async {
    SharedPreferences.setMockInitialValues({
      MovieNightPreset.storageKey: _preset.encodeStored(),
    });
    final gate = Completer<void>();
    final blocking = ConfigurationWrites.run(() => gate.future);
    var current = true;
    final reading = MovieNightStore().read(
      serverUrl: _preset.serverUrl,
      isCurrent: () => current,
    );
    final expectation = expectLater(reading, throwsStateError);
    current = false;
    gate.complete();
    await blocking;
    await expectation;
  });
}
