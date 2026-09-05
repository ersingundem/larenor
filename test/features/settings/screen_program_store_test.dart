import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/settings/data/screen_program_store.dart';
import 'package:larenor/features/settings/domain/screen_program.dart';
import 'package:larenor/features/settings/providers/screen_program_provider.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store implements ScreenProgramStore {
  String? value;
  bool fail = false;
  int writes = 0;
  Completer<void>? pending;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String raw) async {
    writes++;
    await pending?.future;
    if (fail) throw StateError('private storage failure');
    value = raw;
  }
}

ScreenProgram _weekly() => ScreenProgram(
  enabled: true,
  rules: [
    ScreenProgramRule(
      id: 'weekend',
      days: {6, 7},
      startMinutes: 0,
      endMinutes: 1440,
      awake: ScreenAwakeMode.keepAwake,
    ),
  ],
);

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('legacy read preserves raw keys and behavior without writing a weekly program', () async {
    final original = <String, Object>{
      'night_start_minutes': 1320,
      'night_end_minutes': 420,
      'dim_brightness_at_night': true,
      'screen_off_at_night': true,
    };
    SharedPreferences.setMockInitialValues(original);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final program = await container.read(screenProgramProvider.future);
    expect(program.enabled, isTrue);
    expect(
      program.evaluate(DateTime(2026, 9, 5, 23), defaultKeepAwake: true),
      const ScreenPolicy(keepAwake: false, dim: true),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), original.keys.toSet());
    for (final key in original.keys) {
      expect(prefs.get(key), original[key]);
    }
  });
  test('legacy equal endpoints remain inactive and unchanged', () async {
    SharedPreferences.setMockInitialValues({
      'night_start_minutes': 420,
      'night_end_minutes': 420,
      'screen_off_at_night': true,
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final p = await c.read(screenProgramProvider.future);
    expect(p.rules.single.startMinutes, 420);
    expect(p.rules.single.endMinutes, 420);
    expect(
      p.evaluate(DateTime(2026, 9, 5, 7), defaultKeepAwake: true).keepAwake,
      isTrue,
    );
  });
  test(
    'weekly raw data wins and legacy edits cannot restore old policy',
    () async {
      final store = _Store()..value = _weekly().encode();
      final c = ProviderContainer(
        overrides: [screenProgramStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      expect(
        (await c.read(screenProgramProvider.future)).rules.single.id,
        'weekend',
      );
      await c.read(nightWindowProvider.future);
      await c.read(nightWindowProvider.notifier).setDimBrightnessAtNight(true);
      await _settle();
      expect(
        (await c.read(screenProgramProvider.future)).rules.single.id,
        'weekend',
      );
      expect(store.writes, 0);
    },
  );
  test(
    'bad existing weekly data is an error, never a silent legacy fallback',
    () async {
      final store = _Store()..value = '{"version":99}';
      final c = ProviderContainer(
        overrides: [screenProgramStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      await expectLater(
        c.read(screenProgramProvider.future),
        throwsFormatException,
      );
      expect(c.read(screenProgramProvider).hasError, isTrue);
      expect(store.writes, 0);
    },
  );
  test('preference adapter rejects wrong raw type', () async {
    SharedPreferences.setMockInitialValues({ScreenProgram.preferenceKey: 42});
    await expectLater(
      PreferenceScreenProgramStore().read(),
      throwsFormatException,
    );
  });
  test('successful save survives new provider container and preserves legacy settings', () async {
    SharedPreferences.setMockInitialValues({'night_start_minutes': 600});
    final c = ProviderContainer();
    await c.read(screenProgramProvider.future);
    await c
        .read(screenProgramProvider.notifier)
        .save(_weekly(), isCurrent: () => true);
    c.dispose();
    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    expect(
      (await fresh.read(screenProgramProvider.future)).encode(),
      _weekly().encode(),
    );
    expect(
      (await SharedPreferences.getInstance()).getInt('night_start_minutes'),
      600,
    );
  });
  test(
    'pending or failed write never publishes an unpersisted schedule',
    () async {
      final store = _Store()
        ..pending = Completer<void>()
        ..fail = true;
      final c = ProviderContainer(
        overrides: [screenProgramStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final before = await c.read(screenProgramProvider.future);
      final save = c
          .read(screenProgramProvider.notifier)
          .save(_weekly(), isCurrent: () => true);
      final assertion = expectLater(save, throwsStateError);
      await _settle();
      expect(identical(c.read(screenProgramProvider).value, before), isTrue);
      store.pending!.complete();
      await assertion;
      expect(identical(c.read(screenProgramProvider).value, before), isTrue);
      expect(store.value, isNull);
    },
  );
  test(
    'queued save rechecks expired interaction before storage writes',
    () async {
      final store = _Store();
      final c = ProviderContainer(
        overrides: [screenProgramStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      await c.read(screenProgramProvider.future);
      final block = Completer<void>();
      final lock = ConfigurationWrites.run(() => block.future);
      var current = true;
      final save = c
          .read(screenProgramProvider.notifier)
          .save(_weekly(), isCurrent: () => current);
      final assertion = expectLater(save, throwsStateError);
      current = false;
      block.complete();
      await lock;
      await assertion;
      expect(store.writes, 0);
    },
  );
  test('queued disposed owner performs zero writes', () async {
    final store = _Store();
    final c = ProviderContainer(
      overrides: [screenProgramStoreProvider.overrideWithValue(store)],
    );
    await c.read(screenProgramProvider.future);
    final block = Completer<void>();
    final lock = ConfigurationWrites.run(() => block.future);
    final save = c
        .read(screenProgramProvider.notifier)
        .save(_weekly(), isCurrent: () => true);
    final assertion = expectLater(save, throwsStateError);
    c.dispose();
    block.complete();
    await lock;
    await assertion;
    expect(store.writes, 0);
  });
  test('invalid in-memory rule is rejected before durable writes', () async {
    final store = _Store();
    final c = ProviderContainer(
      overrides: [screenProgramStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);
    await c.read(screenProgramProvider.future);
    final invalid = ScreenProgram(
      rules: [
        ScreenProgramRule(id: 'x', days: {}, startMinutes: 0, endMinutes: 1),
      ],
    );
    await expectLater(
      c
          .read(screenProgramProvider.notifier)
          .save(invalid, isCurrent: () => true),
      throwsFormatException,
    );
    expect(store.writes, 0);
  });
}
