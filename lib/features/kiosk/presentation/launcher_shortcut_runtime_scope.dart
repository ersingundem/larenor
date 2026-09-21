import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/launcher_shortcut_api.dart';
import '../domain/launcher_shortcut_models.dart';

/// Consumes only closed native shortcut actions. Background events are dropped;
/// resuming asks native code for one bounded pending user launch.
final class LauncherShortcutRuntimeScope extends StatefulWidget {
  const LauncherShortcutRuntimeScope({
    super.key,
    required this.navigate,
    required this.child,
    this.api,
  });

  final ValueChanged<String> navigate;
  final Widget child;
  final LauncherShortcutApi? api;

  @override
  State<LauncherShortcutRuntimeScope> createState() =>
      _LauncherShortcutRuntimeScopeState();
}

final class _LauncherShortcutRuntimeScopeState
    extends State<LauncherShortcutRuntimeScope>
    with WidgetsBindingObserver {
  late final LauncherShortcutApi _api =
      widget.api ?? AndroidLauncherShortcutApi();
  StreamSubscription<LauncherShortcutAction>? _subscription;
  bool _foreground = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _subscription = _api.actions.listen(
      _dispatch,
      onError: (_) {
        // Invalid or unavailable native events never become navigation.
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeInitial());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    _generation++;
    if (foreground) _takeInitial();
  }

  Future<void> _takeInitial() async {
    final generation = _generation;
    if (!mounted || !_foreground) return;
    try {
      final action = await _api.takeInitial();
      if (mounted &&
          _foreground &&
          generation == _generation &&
          action != null) {
        widget.navigate(action.location);
      }
    } catch (_) {
      // Launcher shortcuts are convenience navigation, never authority.
    }
  }

  void _dispatch(LauncherShortcutAction action) {
    if (!mounted || !_foreground) return;
    widget.navigate(action.location);
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
