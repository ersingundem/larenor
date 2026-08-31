import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';

void main() {
  group('same-day window (e.g. 09:00 -> 17:00)', () {
    const window = NightWindowSettings(
      startMinutes: 9 * 60,
      endMinutes: 17 * 60,
      dimBrightnessAtNight: false,
      screenOffAtNight: false,
    );

    test('is night inside the window', () {
      expect(window.isNightNow(DateTime(2026, 1, 1, 12, 0)), isTrue);
    });

    test('is not night before the window', () {
      expect(window.isNightNow(DateTime(2026, 1, 1, 8, 59)), isFalse);
    });

    test('is not night after the window', () {
      expect(window.isNightNow(DateTime(2026, 1, 1, 17, 0)), isFalse);
    });

    test('start boundary is inclusive', () {
      expect(window.isNightNow(DateTime(2026, 1, 1, 9, 0)), isTrue);
    });
  });

  group('overnight window wrapping midnight (22:00 -> 07:00)', () {
    const window = NightWindowSettings(
      startMinutes: 22 * 60,
      endMinutes: 7 * 60,
      dimBrightnessAtNight: true,
      screenOffAtNight: true,
    );

    test('is night late at night', () {
      expect(window.isNightNow(DateTime(2026, 1, 1, 23, 30)), isTrue);
    });

    test('is night early in the morning', () {
      expect(window.isNightNow(DateTime(2026, 1, 1, 3, 0)), isTrue);
    });

    test('is not night mid-afternoon', () {
      expect(window.isNightNow(DateTime(2026, 1, 1, 14, 0)), isFalse);
    });

    test('end boundary is exclusive', () {
      expect(window.isNightNow(DateTime(2026, 1, 1, 7, 0)), isFalse);
    });
  });

  test('equal start/end means never night', () {
    const window = NightWindowSettings(
      startMinutes: 600,
      endMinutes: 600,
      dimBrightnessAtNight: true,
      screenOffAtNight: true,
    );
    expect(window.isNightNow(DateTime(2026, 1, 1, 10, 0)), isFalse);
    expect(window.isNightNow(DateTime(2026, 1, 1, 0, 0)), isFalse);
  });

  test('copyWith only changes the given fields', () {
    const window = NightWindowSettings(
      startMinutes: 100,
      endMinutes: 200,
      dimBrightnessAtNight: false,
      screenOffAtNight: false,
    );
    final updated = window.copyWith(dimBrightnessAtNight: true);
    expect(updated.startMinutes, 100);
    expect(updated.endMinutes, 200);
    expect(updated.dimBrightnessAtNight, isTrue);
    expect(updated.screenOffAtNight, isFalse);
  });
}
