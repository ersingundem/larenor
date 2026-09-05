import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/providers/window_profile_provider.dart';
import 'window/window_policy_bridge.dart';
import 'window/window_policy_models.dart';
import 'window/window_policy_providers.dart';

/// Kept as the existing app wrapper, but Android's per-window native policy is
/// now the sole system-bar owner. Panel preference never grants kiosk rights.
class ImmersiveModeGuard extends ConsumerStatefulWidget {
  const ImmersiveModeGuard({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<ImmersiveModeGuard> createState() => _ImmersiveModeGuardState();
}

class _ImmersiveModeGuardState extends ConsumerState<ImmersiveModeGuard> {
  // A late completion from a replaced wrapper must not reset its successor.
  static final _owners = Expando<Object>();
  late final WindowPolicyBridge _bridge;
  WindowProfile _desired = WindowProfile.adaptive;
  WindowProfile? _applied;
  bool _running = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _bridge = ref.read(windowPolicyBridgeProvider);
    _owners[_bridge] = this;
    ref.listenManual(windowProfileProvider, (_, next) {
      if (_disposed) return;
      _desired = next.isLoading || next.hasError
          ? WindowProfile.adaptive
          : next.value ?? WindowProfile.adaptive;
      _reconcile();
    }, fireImmediately: true);
  }

  Future<void> _reconcile() async {
    if (_running) return;
    _running = true;
    try {
      while (identical(_owners[_bridge], this) && _applied != _desired) {
        final requested = _desired;
        // The bridge redacts native failures and reports an unknown snapshot.
        // A storage change arriving during this call is reconciled next.
        try {
          await _bridge.setProfile(requested);
        } catch (_) {
          // Injected/unsupported hosts must not crash app startup or disposal.
        }
        _applied = requested;
      }
    } finally {
      _running = false;
      if (_disposed && identical(_owners[_bridge], this)) {
        _owners[_bridge] = null;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _desired = WindowProfile.adaptive;
    _reconcile();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
