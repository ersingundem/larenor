import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_interaction_scope.dart';
import 'home_session_controller.dart';

/// Source retirement composes with the window/idle gate; neither can reopen
/// an action captured before the other controller's epoch changed.
class HomeInteractionGate extends ConsumerStatefulWidget {
  const HomeInteractionGate({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<HomeInteractionGate> createState() =>
      _HomeInteractionGateState();
}

class _HomeInteractionGateState extends ConsumerState<HomeInteractionGate> {
  final _combined = AppInteractionController(active: false);
  AppInteractionController? _window;
  AppInteractionController? _home;
  int _windowEpoch = 0, _homeEpoch = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final window = AppInteractionScope.maybeOf(context);
    final home = ref.read(homeSessionControllerProvider)?.interaction;
    if (!identical(window, _window) || !identical(home, _home)) {
      _window?.removeListener(_sync);
      _home?.removeListener(_sync);
      _window = window;
      _home = home;
      _window?.addListener(_sync);
      _home?.addListener(_sync);
      _sync();
    }
  }

  void _sync() {
    final windowEpoch = _window?.epoch ?? 0;
    final homeEpoch = _home?.epoch ?? 0;
    if (windowEpoch != _windowEpoch || homeEpoch != _homeEpoch) {
      _combined.setActive(false);
    }
    _windowEpoch = windowEpoch;
    _homeEpoch = homeEpoch;
    _combined.setActive((_window?.active ?? true) && (_home?.active ?? true));
  }

  @override
  void dispose() {
    _window?.removeListener(_sync);
    _home?.removeListener(_sync);
    _combined.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppInteractionScope(
    controller: _combined,
    child: ListenableBuilder(
      listenable: _combined,
      builder: (_, child) => TickerMode(
        enabled: _combined.active,
        child: ExcludeFocus(
          excluding: !_combined.active,
          child: ExcludeSemantics(
            excluding: !_combined.active,
            child: IgnorePointer(ignoring: !_combined.active, child: child),
          ),
        ),
      ),
      child: widget.child,
    ),
  );
}
