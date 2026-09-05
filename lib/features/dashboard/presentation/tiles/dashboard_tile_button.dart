import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../../core/app_interaction_scope.dart';

class _TileMenuIntent extends Intent {
  const _TileMenuIntent();
}

/// A whole-card action. Interactive child controls belong outside this wrapper.
/// The inset keeps Cupertino's native focus outline inside a clipped grid cell.
class DashboardTileButton extends StatefulWidget {
  const DashboardTileButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.child,
    this.onLongPress,
  });

  static const focusInset = 4.0;
  final String label;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final Widget child;

  @override
  State<DashboardTileButton> createState() => _DashboardTileButtonState();
}

class _DashboardTileButtonState extends State<DashboardTileButton> {
  late final AppLifecycleListener _lifecycle;
  bool _foreground = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final foreground = state == AppLifecycleState.resumed;
        if (_foreground == foreground) return;
        if (!foreground) _generation++;
        setState(() => _foreground = foreground);
      },
    );
  }

  @override
  void didUpdateWidget(covariant DashboardTileButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onPressed != widget.onPressed ||
        oldWidget.onLongPress != widget.onLongPress) {
      _generation++;
    }
  }

  @override
  void dispose() {
    _generation++;
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);
    final interaction = AppInteractionScope.maybeOf(context);
    final epoch = interaction?.epoch;
    final generation = _generation;
    bool current() =>
        mounted &&
        _foreground &&
        generation == _generation &&
        identical(interaction, AppInteractionScope.maybeRead(context)) &&
        interaction?.active != false &&
        interaction?.epoch == epoch &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false;
    // A nonopaque menu temporarily covers this route. Preserve the native
    // focus node for restoration on dismissal, while current() still rejects
    // callbacks behind it. Hidden branches and inactive windows cannot focus.
    final enabled =
        _foreground &&
        interaction?.active != false &&
        TickerMode.valuesOf(context).enabled &&
        (widget.onPressed != null || widget.onLongPress != null);
    VoidCallback? guard(VoidCallback? callback) => callback == null || !enabled
        ? null
        : () {
            if (current()) callback();
          };
    final onPressed = guard(widget.onPressed);
    final onLongPress = guard(widget.onLongPress);
    return Semantics(
      label: widget.label,
      enabled: enabled,
      blockUserActions: !enabled,
      child: Padding(
        padding: const EdgeInsets.all(DashboardTileButton.focusInset),
        child: Shortcuts(
          shortcuts: onLongPress == null
              ? const {}
              : const {
                  SingleActivator(LogicalKeyboardKey.contextMenu):
                      _TileMenuIntent(),
                  SingleActivator(LogicalKeyboardKey.f10, shift: true):
                      _TileMenuIntent(),
                },
          child: Actions(
            actions: {
              if (onLongPress != null)
                _TileMenuIntent: CallbackAction<_TileMenuIntent>(
                  onInvoke: (_) {
                    onLongPress?.call();
                    return null;
                  },
                ),
            },
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size.square(48),
              borderRadius: BorderRadius.circular(18),
              focusColor:
                  CupertinoTheme.brightnessOf(context) == Brightness.dark
                  ? Color.lerp(theme.primaryColor, CupertinoColors.white, .12)
                  : theme.primaryColor,
              onPressed: onPressed,
              onLongPress: onLongPress,
              child: ExcludeSemantics(
                child: DefaultTextStyle(
                  style: DefaultTextStyle.of(context).style,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
