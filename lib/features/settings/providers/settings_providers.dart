import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/theme.dart';
import '../data/pin_lock_store.dart';

part 'settings_providers.g.dart';

const _keepScreenOnKey = 'keep_screen_on';
const _appearanceKey = 'appearance';

/// Whether the screen should stay on continuously — the default posture for
/// a wall-mounted tablet dashboard.
@riverpod
class KeepScreenOn extends _$KeepScreenOn {
  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool(_keepScreenOnKey) ?? false;
    await _apply(value);
    return value;
  }

  Future<void> set(bool value) async {
    state = AsyncData(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepScreenOnKey, value);
    await _apply(value);
  }

  Future<void> _apply(bool value) {
    return value ? WakelockPlus.enable() : WakelockPlus.disable();
  }
}

/// Light/dark preference. Defaults to following the tablet's own setting,
/// which is what the app did before this was configurable.
@riverpod
class Appearance extends _$Appearance {
  @override
  Future<AppAppearance> build() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_appearanceKey);
    return AppAppearance.values.firstWhere(
      (value) => value.name == stored,
      orElse: () => AppAppearance.system,
    );
  }

  Future<void> set(AppAppearance value) async {
    state = AsyncData(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appearanceKey, value.name);
  }
}

@riverpod
PinLockStore pinLockStore(Ref ref) => PinLockStore();

/// The Settings-access PIN, if one has been set. `null` means Settings is
/// unlocked for anyone — the default, matching the MVP's behavior.
@riverpod
class PinLock extends _$PinLock {
  @override
  Future<String?> build() => ref.watch(pinLockStoreProvider).read();

  Future<void> setPin(String pin) async {
    await ref.read(pinLockStoreProvider).save(pin);
    state = AsyncData(pin);
  }

  Future<void> clearPin() async {
    await ref.read(pinLockStoreProvider).clear();
    state = const AsyncData(null);
  }
}

/// Minutes-since-midnight window (e.g. 22:00 -> 07:00) used to dim the
/// screen and/or let it turn off overnight — the wall-panel equivalent of a
/// day/night theme. A single shared window drives both effects so there's
/// one thing to configure, not two.
class NightWindowSettings {
  const NightWindowSettings({
    required this.startMinutes,
    required this.endMinutes,
    required this.dimBrightnessAtNight,
    required this.screenOffAtNight,
  });

  final int startMinutes;
  final int endMinutes;
  final bool dimBrightnessAtNight;
  final bool screenOffAtNight;

  bool isNightNow([DateTime? now]) {
    final current = now ?? DateTime.now();
    final nowMinutes = current.hour * 60 + current.minute;
    if (startMinutes == endMinutes) return false;
    if (startMinutes < endMinutes) {
      return nowMinutes >= startMinutes && nowMinutes < endMinutes;
    }
    // Window wraps past midnight, e.g. 22:00 -> 07:00.
    return nowMinutes >= startMinutes || nowMinutes < endMinutes;
  }

  NightWindowSettings copyWith({
    int? startMinutes,
    int? endMinutes,
    bool? dimBrightnessAtNight,
    bool? screenOffAtNight,
  }) {
    return NightWindowSettings(
      startMinutes: startMinutes ?? this.startMinutes,
      endMinutes: endMinutes ?? this.endMinutes,
      dimBrightnessAtNight: dimBrightnessAtNight ?? this.dimBrightnessAtNight,
      screenOffAtNight: screenOffAtNight ?? this.screenOffAtNight,
    );
  }
}

const _nightStartKey = 'night_start_minutes';
const _nightEndKey = 'night_end_minutes';
const _dimAtNightKey = 'dim_brightness_at_night';
const _screenOffAtNightKey = 'screen_off_at_night';

@riverpod
class NightWindow extends _$NightWindow {
  @override
  Future<NightWindowSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    return NightWindowSettings(
      startMinutes: prefs.getInt(_nightStartKey) ?? 22 * 60,
      endMinutes: prefs.getInt(_nightEndKey) ?? 7 * 60,
      dimBrightnessAtNight: prefs.getBool(_dimAtNightKey) ?? false,
      screenOffAtNight: prefs.getBool(_screenOffAtNightKey) ?? false,
    );
  }

  Future<void> setStartMinutes(int minutes) async {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(startMinutes: minutes));
    (await SharedPreferences.getInstance()).setInt(_nightStartKey, minutes);
  }

  Future<void> setEndMinutes(int minutes) async {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(endMinutes: minutes));
    (await SharedPreferences.getInstance()).setInt(_nightEndKey, minutes);
  }

  Future<void> setDimBrightnessAtNight(bool value) async {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(dimBrightnessAtNight: value));
    (await SharedPreferences.getInstance()).setBool(_dimAtNightKey, value);
  }

  Future<void> setScreenOffAtNight(bool value) async {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(screenOffAtNight: value));
    (await SharedPreferences.getInstance()).setBool(
      _screenOffAtNightKey,
      value,
    );
  }
}

/// Idle/ambient-mode configuration — after [timeoutMinutes] of no touch
/// input, the dashboard is replaced with a low-distraction clock screen.
class IdleModeSettings {
  const IdleModeSettings({required this.enabled, required this.timeoutMinutes});

  final bool enabled;
  final int timeoutMinutes;

  IdleModeSettings copyWith({bool? enabled, int? timeoutMinutes}) {
    return IdleModeSettings(
      enabled: enabled ?? this.enabled,
      timeoutMinutes: timeoutMinutes ?? this.timeoutMinutes,
    );
  }
}

const _idleEnabledKey = 'idle_mode_enabled';
const _idleTimeoutKey = 'idle_timeout_minutes';

@riverpod
class IdleMode extends _$IdleMode {
  @override
  Future<IdleModeSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    return IdleModeSettings(
      enabled: prefs.getBool(_idleEnabledKey) ?? false,
      timeoutMinutes: prefs.getInt(_idleTimeoutKey) ?? 5,
    );
  }

  Future<void> setEnabled(bool value) async {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(enabled: value));
    (await SharedPreferences.getInstance()).setBool(_idleEnabledKey, value);
  }

  Future<void> setTimeoutMinutes(int minutes) async {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(timeoutMinutes: minutes));
    (await SharedPreferences.getInstance()).setInt(_idleTimeoutKey, minutes);
  }
}
