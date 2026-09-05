import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/window/window_policy_models.dart';
import '../../../core/window/window_policy_providers.dart';
import '../data/screen_policy_controller.dart';
import '../domain/screen_program.dart';
import '../providers/screen_program_provider.dart';
import '../providers/settings_providers.dart';

final screenPolicyControllerProvider = Provider<ScreenPolicyController>(
  (ref) => ScreenPolicyController.application,
);
final screenPolicyClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// Foreground, local wall-clock policy only. No alarms or screen-off command.
class ScreenPolicyRunner extends ConsumerStatefulWidget {
  const ScreenPolicyRunner({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<ScreenPolicyRunner> createState() => _ScreenPolicyRunnerState();
}

class _ScreenPolicyRunnerState extends ConsumerState<ScreenPolicyRunner>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _foreground = true, _focused = true;
  late final ScreenPolicyController _controller;
  late final Object _owner;
  int? _viewId;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _controller = ref.read(screenPolicyControllerProvider);
    _owner = _controller.claim();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId = View.of(context).viewId;
    _apply(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _apply(force: true);
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    _focused = event.state == ViewFocusState.focused;
    _apply(force: true);
  }

  bool _windowAvailable() {
    final reading = ref.read(windowPolicySnapshotProvider);
    if (reading.isLoading || reading.hasError || !reading.hasValue) {
      return false;
    }
    final window = reading.requireValue;
    // The Android-specific bridge is absent on other supported Flutter hosts.
    if (!window.supported) return true;
    return window.isResumed &&
        window.hasWindowFocus &&
        !window.isPictureInPicture &&
        !window.isExternalDisplay &&
        window.reason != WindowRestrictionReason.unknown;
  }

  void _apply({bool force = false}) {
    if (!mounted) return;
    _timer?.cancel();
    final active = _foreground && _focused && _windowAvailable();
    final reading = ref.read(screenProgramProvider);
    final keep = ref.read(keepScreenOnProvider);
    final now = ref.read(screenPolicyClockProvider)();
    final valid =
        !reading.isLoading &&
        !reading.hasError &&
        reading.hasValue &&
        !keep.isLoading &&
        !keep.hasError &&
        keep.hasValue;
    _controller.update(
      _owner,
      active && valid
          ? reading.requireValue.evaluate(
              now,
              defaultKeepAwake: keep.requireValue,
            )
          : ScreenPolicy.released,
      force: force,
    );
    if (active) {
      // Real elapsed scheduling, wall-time evaluation: jumps, folds and a
      // changed device timezone are reconciled within the next foreground minute.
      final delay = Duration(
        milliseconds: 60000 - now.second * 1000 - now.millisecond,
      );
      _timer = Timer(delay, () => _apply());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _controller.release(_owner);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(screenProgramProvider, (_, _) => _apply());
    ref.listen(keepScreenOnProvider, (_, _) => _apply());
    ref.listen(windowPolicySnapshotProvider, (_, _) => _apply(force: true));
    return widget.child;
  }
}
