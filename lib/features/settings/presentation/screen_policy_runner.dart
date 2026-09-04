import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../providers/settings_providers.dart';

const _dimBrightness = 0.05;

/// One serialized owner for the app's night brightness and wakelock policy.
/// Backgrounding releases both overrides; resuming uses the latest settings.
class ScreenPolicyRunner extends ConsumerStatefulWidget {
  const ScreenPolicyRunner({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ScreenPolicyRunner> createState() => _ScreenPolicyRunnerState();
}

class _ScreenPolicyRunnerState extends ConsumerState<ScreenPolicyRunner>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _foreground = true;
  bool _applying = false;
  bool _pending = false;
  bool _disposed = false;
  bool? _lastWakelock;
  bool _dimmed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _restartTimer();
    _apply();
  }

  void _restartTimer() {
    _timer?.cancel();
    if (_foreground && !_disposed) {
      _timer = Timer.periodic(const Duration(minutes: 1), (_) => _apply());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _restartTimer();
    _apply();
  }

  @override
  void dispose() {
    _disposed = true;
    _foreground = false;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // Reconcile after an outstanding plugin call rather than racing it.
    _apply();
    super.dispose();
  }

  Future<void> _apply() async {
    _pending = true;
    if (_applying) return;
    _applying = true;
    try {
      while (_pending) {
        _pending = false;
        final keepOn =
            !_disposed && (ref.read(keepScreenOnProvider).value ?? false);
        final window = _disposed ? null : ref.read(nightWindowProvider).value;
        final isNight = window?.isNightNow() ?? false;
        final stayOn =
            _foreground &&
            keepOn &&
            !(window?.screenOffAtNight == true && isNight);
        if (_lastWakelock != stayOn) {
          try {
            await WakelockPlus.toggle(enable: stayOn);
            _lastWakelock = stayOn;
          } catch (_) {
            // Unsupported devices/platform failures must not escape a timer.
          }
        }
        // The desired state may have changed during the platform call.
        if (_pending) continue;
        final dim =
            _foreground && isNight && window?.dimBrightnessAtNight == true;
        if (dim != _dimmed) {
          try {
            if (dim) {
              await ScreenBrightness.instance.setApplicationScreenBrightness(
                _dimBrightness,
              );
            } else {
              await ScreenBrightness.instance
                  .resetApplicationScreenBrightness();
            }
            _dimmed = dim;
          } catch (_) {
            // Restoring the device preference needs no WRITE_SETTINGS grant.
          }
        }
      }
    } finally {
      _applying = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(keepScreenOnProvider, (_, _) => _apply());
    ref.listen(nightWindowProvider, (_, _) => _apply());
    return widget.child;
  }
}
