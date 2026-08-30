import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

part 'settings_providers.g.dart';

const _keepScreenOnKey = 'keep_screen_on';

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
