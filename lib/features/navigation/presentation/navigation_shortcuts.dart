import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../core/app_interaction_scope.dart';

/// Navigation only. Dialogs and protected routes own their own input scope.
class NavigationShortcuts extends StatefulWidget {
  const NavigationShortcuts({
    super.key,
    required this.child,
    required this.onSearch,
    required this.onSelectRoot,
  });

  final Widget child;
  final VoidCallback onSearch;
  final ValueChanged<int> onSelectRoot;

  @override
  State<NavigationShortcuts> createState() => _NavigationShortcutsState();
}

class _NavigationShortcutsState extends State<NavigationShortcuts> {
  final _focus = FocusNode(debugLabel: 'Root navigation');
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool canNavigate() {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
        return false;
      }
      if (AppInteractionScope.maybeRead(context)?.active == false) return false;
      if (ModalRoute.of(context)?.isCurrent == false) return false;
      final focused = FocusManager.instance.primaryFocus?.context;
      final focusedRoute = focused == null ? null : ModalRoute.of(focused);
      return focusedRoute is! PopupRoute && focusedRoute?.isCurrent != false;
    }

    return FocusTraversalGroup(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(
            LogicalKeyboardKey.keyK,
            control: true,
            includeRepeats: false,
          ): () {
            if (canNavigate()) widget.onSearch();
          },
          for (final entry in {
            LogicalKeyboardKey.digit1: 0,
            LogicalKeyboardKey.digit2: 1,
            LogicalKeyboardKey.digit3: 2,
            LogicalKeyboardKey.digit4: 3,
          }.entries)
            SingleActivator(
              entry.key,
              control: true,
              includeRepeats: false,
            ): () {
              if (canNavigate()) {
                widget.onSelectRoot(entry.value);
                _focus.requestFocus();
              }
            },
        },
        child: Focus(focusNode: _focus, autofocus: true, child: widget.child),
      ),
    );
  }
}
