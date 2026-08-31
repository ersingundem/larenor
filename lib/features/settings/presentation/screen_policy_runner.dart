import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../providers/settings_providers.dart';

const _dimBrightness = 0.05;
const _dayBrightness = 1.0;

/// Wraps the whole app and continuously reconciles the "keep screen on"
/// toggle with the night window (dim brightness / let the screen turn off
/// overnight) — one policy engine instead of three independent timers.
/// Ticks once a minute and immediately on any relevant setting change.
class ScreenPolicyRunner extends ConsumerStatefulWidget {
  const ScreenPolicyRunner({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ScreenPolicyRunner> createState() => _ScreenPolicyRunnerState();
}

class _ScreenPolicyRunnerState extends ConsumerState<ScreenPolicyRunner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _apply();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _apply());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _apply() async {
    final keepScreenOn = ref.read(keepScreenOnProvider).value ?? false;
    final window = ref.read(nightWindowProvider).value;
    if (window == null) return;

    final isNight = window.isNightNow();

    final shouldStayOn = keepScreenOn && !(window.screenOffAtNight && isNight);
    await (shouldStayOn ? WakelockPlus.enable() : WakelockPlus.disable());

    if (window.dimBrightnessAtNight) {
      try {
        await ScreenBrightness.instance.setSystemScreenBrightness(
          isNight ? _dimBrightness : _dayBrightness,
        );
      } catch (_) {
        // Some devices (emulators, or without the WRITE_SETTINGS grant)
        // don't support system brightness control — degrade silently.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(keepScreenOnProvider, (_, _) => _apply());
    ref.listen(nightWindowProvider, (_, _) => _apply());
    return widget.child;
  }
}
