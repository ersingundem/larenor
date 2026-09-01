import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Re-applies fullscreen (status/navigation bars hidden) whenever the app
/// returns to the foreground — Android resets system UI visibility on
/// resume (e.g. after a permission dialog, or switching back from another
/// app), so the one-shot call in `main()` isn't enough on its own for a
/// wall-panel app that's meant to always be fullscreen.
class ImmersiveModeGuard extends StatefulWidget {
  const ImmersiveModeGuard({super.key, required this.child});

  final Widget child;

  @override
  State<ImmersiveModeGuard> createState() => _ImmersiveModeGuardState();
}

class _ImmersiveModeGuardState extends State<ImmersiveModeGuard>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
