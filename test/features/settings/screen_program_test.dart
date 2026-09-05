import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/settings/domain/screen_program.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

ScreenProgram _program({
  Set<int> days = const {1},
  int start = 1320,
  int end = 420,
  ScreenAwakeMode awake = ScreenAwakeMode.systemTimeout,
  bool dim = true,
}) => ScreenProgram(
  enabled: true,
  rules: [
    ScreenProgramRule(
      id: 'rule',
      days: days,
      startMinutes: start,
      endMinutes: end,
      awake: awake,
      dim: dim,
    ),
  ],
);
void main() {
  test('overnight weekdays follow the starting day, including Sunday wrap', () {
    final p = _program();
    expect(
      p.evaluate(DateTime(2026, 1, 5, 22), defaultKeepAwake: true).dim,
      true,
    );
    expect(
      p.evaluate(DateTime(2026, 1, 6, 6, 59), defaultKeepAwake: true).dim,
      true,
    );
    expect(
      p.evaluate(DateTime(2026, 1, 6, 7), defaultKeepAwake: true).dim,
      false,
    );
    expect(
      p.evaluate(DateTime(2026, 1, 5, 6), defaultKeepAwake: true).dim,
      false,
    );
    final sun = _program(days: {7});
    expect(
      sun.evaluate(DateTime(2026, 1, 5, 6), defaultKeepAwake: true).dim,
      true,
    );
  });
  test('all day end 1440 is exclusive and equal endpoints are inert', () {
    final p = _program(start: 0, end: 1440);
    expect(
      p.evaluate(DateTime(2026, 1, 5, 23, 59), defaultKeepAwake: false).dim,
      true,
    );
    expect(
      p.evaluate(DateTime(2026, 1, 6), defaultKeepAwake: false).dim,
      false,
    );
    expect(
      _program(
        start: 100,
        end: 100,
      ).evaluate(DateTime(2026, 1, 5, 2), defaultKeepAwake: true),
      const ScreenPolicy(keepAwake: true, dim: false),
    );
  });
  test('last matching rule wins whole policy and dim never implies awake', () {
    final p = ScreenProgram(
      enabled: true,
      rules: [
        ..._program(
          start: 0,
          end: 1440,
          awake: ScreenAwakeMode.keepAwake,
        ).rules,
        ScreenProgramRule(
          id: 'second',
          days: {1},
          startMinutes: 600,
          endMinutes: 660,
          dim: true,
        ),
      ],
    );
    expect(
      p.evaluate(DateTime(2026, 1, 5, 10), defaultKeepAwake: false),
      const ScreenPolicy(keepAwake: false, dim: true),
    );
    expect(
      p.evaluate(DateTime(2026, 1, 5, 11), defaultKeepAwake: false),
      const ScreenPolicy(keepAwake: true, dim: true),
    );
  });
  test('all legacy flag combinations and hours preserve previous behavior', () {
    for (final dim in [false, true]) {
      for (final off in [false, true]) {
        for (final interval in [(1320, 420), (540, 1020), (600, 600)]) {
          final old = NightWindowSettings(
            startMinutes: interval.$1,
            endMinutes: interval.$2,
            dimBrightnessAtNight: dim,
            screenOffAtNight: off,
          );
          final migrated = ScreenProgram.legacy(
            startMinutes: interval.$1,
            endMinutes: interval.$2,
            dim: dim,
            systemTimeout: off,
          );
          for (final keep in [false, true]) {
            for (var hour = 0; hour < 48; hour++) {
              final now = DateTime(2026, 1, 5, hour);
              final active = old.isNightNow(now);
              expect(
                migrated.evaluate(now, defaultKeepAwake: keep),
                ScreenPolicy(
                  keepAwake: keep && !(off && active),
                  dim: dim && active,
                ),
              );
            }
          }
          expect(
            ScreenProgram.decode(migrated.encode()).encode(),
            migrated.encode(),
          );
        }
      }
    }
  });
  test('DST missing hour and repeated hour use actual local wall time', () {
    tzdata.initializeTimeZones();
    final zone = tz.getLocation('America/New_York');
    final spring = _program(days: {7}, start: 120, end: 240);
    final before = tz.TZDateTime.from(DateTime.utc(2026, 3, 8, 6, 59), zone);
    final after = tz.TZDateTime.from(DateTime.utc(2026, 3, 8, 7), zone);
    expect(before.hour, 1);
    expect(after.hour, 3);
    expect(spring.evaluate(before, defaultKeepAwake: true).dim, false);
    expect(spring.evaluate(after, defaultKeepAwake: true).dim, true);
    final folded = _program(days: {7}, start: 60, end: 120);
    for (final utcHour in [5, 6]) {
      final local = tz.TZDateTime.from(
        DateTime.utc(2026, 11, 1, utcHour, 30),
        zone,
      );
      expect(local.hour, 1);
      expect(folded.evaluate(local, defaultKeepAwake: true).dim, true);
    }
    expect(
      folded
          .evaluate(
            tz.TZDateTime.from(DateTime.utc(2026, 11, 1, 7), zone),
            defaultKeepAwake: true,
          )
          .dim,
      false,
    );
  });
  test('changing device timezone changes recurrence without changing saved schedule', () {
    tzdata.initializeTimeZones();
    final instant = DateTime.utc(2026, 1, 5, 18);
    final p = _program(start: 1200, end: 1320);
    expect(
      p
          .evaluate(
            tz.TZDateTime.from(instant, tz.getLocation('Europe/Istanbul')),
            defaultKeepAwake: true,
          )
          .dim,
      true,
    );
    expect(
      p
          .evaluate(
            tz.TZDateTime.from(instant, tz.getLocation('Europe/London')),
            defaultKeepAwake: true,
          )
          .dim,
      false,
    );
  });
  for (final corrupt in <String, void Function(Map<String, dynamic>)>{
    'unknown root': (j) => j['extra'] = true,
    'float version': (j) => j['version'] = 1.0,
    'too many rules': (j) => j['rules'] = List.generate(
      17,
      (i) => {...(j['rules'] as List).first as Map, 'id': 'r$i'},
    ),
    'duplicate ids': (j) =>
        (j['rules'] as List).add((j['rules'] as List).first),
    'unknown field': (j) =>
        ((j['rules'] as List).first as Map)['secret'] = 'bad',
    'wrong day': (j) => ((j['rules'] as List).first as Map)['days'] = [0],
    'duplicate day': (j) =>
        ((j['rules'] as List).first as Map)['days'] = [1, 1],
    'no days': (j) => ((j['rules'] as List).first as Map)['days'] = [],
    'start out of range': (j) =>
        ((j['rules'] as List).first as Map)['startMinutes'] = 1440,
    'end out of range': (j) =>
        ((j['rules'] as List).first as Map)['endMinutes'] = 1441,
    'unknown behavior': (j) =>
        ((j['rules'] as List).first as Map)['awake'] = 'powerOff',
    'control label': (j) =>
        ((j['rules'] as List).first as Map)['name'] = 'bad\nname',
  }.entries) {
    test('strict schema rejects ${corrupt.key}', () {
      final j = jsonDecode(_program().encode()) as Map<String, dynamic>;
      corrupt.value(j);
      expect(() => ScreenProgram.fromJson(j), throwsFormatException);
    });
  }
  test('oversized input and mutable source collections are bounded', () {
    expect(() => ScreenProgram.decode(' ' * 32769), throwsFormatException);
    final days = {1};
    final rule = ScreenProgramRule(
      id: 'x',
      days: days,
      startMinutes: 0,
      endMinutes: 60,
    );
    days.add(2);
    expect(rule.days, {1});
    expect(() => rule.days.add(2), throwsUnsupportedError);
  });
}
