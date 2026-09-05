import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../domain/screen_program.dart';

abstract interface class ScreenPolicyPlatform {
  Future<void> keepAwake(bool enabled);
  Future<void> dim();
  Future<void> resetBrightness();
}

class PluginScreenPolicyPlatform implements ScreenPolicyPlatform {
  @override
  Future<void> keepAwake(bool enabled) => WakelockPlus.toggle(enable: enabled);
  @override
  Future<void> dim() =>
      ScreenBrightness.instance.setApplicationScreenBrightness(0.05);
  @override
  Future<void> resetBrightness() =>
      ScreenBrightness.instance.resetApplicationScreenBrightness();
}

/// A single serialized native owner, shared across configuration-scope remounts.
/// Old owners cannot release a replacement screen's desired policy.
class ScreenPolicyController {
  ScreenPolicyController(this.platform);
  final ScreenPolicyPlatform platform;
  static final application = ScreenPolicyController(
    PluginScreenPolicyPlatform(),
  );
  Object? _owner;
  ScreenPolicy _desired = ScreenPolicy.released;
  bool _running = false, _pending = false;
  bool? _lastAwake;
  bool _lastDim = false, _brightnessClaimed = false;
  int _refreshEpoch = 0;

  Object claim() {
    final owner = Object();
    _owner = owner;
    _desired = ScreenPolicy.released;
    _refreshEpoch++;
    _lastAwake = null;
    _reconcile();
    return owner;
  }

  void update(Object owner, ScreenPolicy policy, {bool force = false}) {
    if (!identical(owner, _owner)) return;
    _desired = policy;
    if (force) {
      _refreshEpoch++;
      _lastAwake = null;
      _lastDim = false;
    }
    _reconcile();
  }

  void release(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _desired = ScreenPolicy.released;
    _reconcile();
  }

  Future<void> _reconcile() async {
    _pending = true;
    if (_running) return;
    _running = true;
    try {
      while (_pending) {
        _pending = false;
        final desired = _desired, epoch = _refreshEpoch;
        if (_lastAwake != desired.keepAwake) {
          try {
            await platform.keepAwake(desired.keepAwake);
            if (epoch == _refreshEpoch) _lastAwake = desired.keepAwake;
          } catch (_) {
            /* A later foreground reconciliation can retry. */
          }
        }
        if (_pending) continue;
        if (desired.dim && !_lastDim) {
          _brightnessClaimed = true;
          try {
            await platform.dim();
            if (epoch == _refreshEpoch) _lastDim = true;
          } catch (_) {
            /* Keep ownership so an eventual reset is attempted. */
          }
        } else if (!desired.dim && _brightnessClaimed) {
          try {
            await platform.resetBrightness();
            _brightnessClaimed = false;
            _lastDim = false;
          } catch (_) {
            /* Do not treat a failed reset as applied. */
          }
        }
      }
    } finally {
      _running = false;
    }
  }
}
