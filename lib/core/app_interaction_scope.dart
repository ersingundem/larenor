import 'package:flutter/widgets.dart';

/// Window-wide permission to begin or continue an interactive operation.
///
/// This is separate from a route being covered by its own dialog, and from the
/// native audio service's lifetime. Losing permission expires captured epochs;
/// waking the window never makes an old confirmation valid again.
class AppInteractionController extends ChangeNotifier {
  // Keep the public constructor parameter separate from the private state.
  // ignore: prefer_initializing_formals
  AppInteractionController({bool active = true}) : _active = active;

  bool _active;
  int _epoch = 0;
  bool get active => _active;
  int get epoch => _epoch;

  void setActive(bool value) {
    if (_active == value) return;
    _active = value;
    if (!value) _epoch++;
    notifyListeners();
  }
}

/// Place above the complete Navigator tree so root dialogs share the policy.
class AppInteractionScope extends InheritedNotifier<AppInteractionController> {
  const AppInteractionScope({
    super.key,
    required AppInteractionController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppInteractionController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppInteractionScope>()
      ?.notifier;

  /// Read the current mutable state in an action callback without subscribing.
  static AppInteractionController? maybeRead(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppInteractionScope>()?.notifier;
}
