import 'package:flutter/cupertino.dart';

/// A whole-card action. Interactive child controls belong outside this wrapper.
/// The inset keeps Cupertino's native focus outline inside a clipped grid cell.
class DashboardTileButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);
    final enabled = onPressed != null || onLongPress != null;
    return Semantics(
      label: label,
      enabled: enabled,
      blockUserActions: !enabled,
      child: Padding(
        padding: const EdgeInsets.all(focusInset),
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size.square(48),
          borderRadius: BorderRadius.circular(18),
          focusColor: CupertinoTheme.brightnessOf(context) == Brightness.dark
              ? Color.lerp(theme.primaryColor, CupertinoColors.white, .12)
              : theme.primaryColor,
          onPressed: onPressed,
          onLongPress: onLongPress,
          child: ExcludeSemantics(
            child: DefaultTextStyle(
              style: DefaultTextStyle.of(context).style,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
