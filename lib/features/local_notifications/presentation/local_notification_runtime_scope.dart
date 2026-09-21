import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/window/window_policy_models.dart';
import '../../../core/window/window_policy_providers.dart';
import '../data/local_notification_controller.dart';
import '../data/local_notification_runtime.dart';
import '../providers/local_notification_providers.dart';

/// Owns foreground notification synchronization for the whole application.
/// Route widgets can disappear without stopping delivery while the verified
/// home runtime and foreground window remain authoritative.
class LocalNotificationRuntimeScope extends ConsumerStatefulWidget {
  const LocalNotificationRuntimeScope({
    super.key,
    required this.navigate,
    required this.child,
  });

  final LocalNotificationNavigate navigate;
  final Widget child;

  static LocalNotificationRuntimeCoordinator of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<
          _LocalNotificationRuntimeInherited
        >();
    assert(scope != null, 'LocalNotificationRuntimeScope is missing');
    return scope!.notifier!;
  }

  @override
  ConsumerState<LocalNotificationRuntimeScope> createState() =>
      _LocalNotificationRuntimeScopeState();
}

class _LocalNotificationRuntimeScopeState
    extends ConsumerState<LocalNotificationRuntimeScope>
    with WidgetsBindingObserver {
  final _owner = _RuntimeOwner();
  late final LocalNotificationRuntimeCoordinator _runtime;
  AppInteractionController? _interaction;
  WindowPolicySnapshot? _window;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final home = ref.read(homeSessionControllerProvider)!;
    _runtime = LocalNotificationRuntimeCoordinator(
      home: home,
      controller: LocalNotificationController(
        home: home,
        apiFactory: ref.read(localNotificationApiFactoryProvider),
        store: ref.read(localNotificationStoreProvider),
        permissionGateway: ref.read(localNotificationPermissionProvider),
        clock: ref.read(localNotificationClockProvider),
        windowCurrent: _current,
        owner: _owner,
      ),
      platform: ref.read(localNotificationPlatformProvider),
      clock: ref.read(localNotificationClockProvider),
      active: _current,
      navigate: (location) => widget.navigate(location),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final interaction = AppInteractionScope.maybeOf(context);
    if (!identical(interaction, _interaction)) {
      _interaction?.removeListener(_sync);
      _interaction = interaction;
      _interaction?.addListener(_sync);
    }
    _sync();
  }

  bool _current() {
    if (!mounted || !(_interaction?.active ?? true)) return false;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return false;
    }
    final window = _window;
    return window != null &&
        (!window.supported ||
            window.isResumed &&
                window.hasWindowFocus &&
                !window.isPictureInPicture);
  }

  void _sync() {
    if (!mounted) return;
    final current = _current();
    _owner.setCurrent(current);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      _runtime.retire();
    } else if (!current &&
        _runtime.permissionPending &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
      _runtime.suspendForPermissionDialog();
    } else {
      _runtime.setEnabled(current);
    }
    _runtime.authorityChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  @override
  void didUpdateWidget(LocalNotificationRuntimeScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    // HomeSessionScope recreates this scope when identity changes. The router
    // itself is stable within that runtime, so a changed callback is a rebuild.
    if (oldWidget.navigate != widget.navigate) _runtime.authorityChanged();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_sync);
    _runtime.dispose();
    _owner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncWindow = ref.watch(windowPolicySnapshotProvider);
    final window = asyncWindow.hasValue ? asyncWindow.requireValue : null;
    if (window != _window) {
      _window = window;
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    }
    return _LocalNotificationRuntimeInherited(
      notifier: _runtime,
      child: widget.child,
    );
  }
}

class _RuntimeOwner extends ChangeNotifier implements LocalNotificationOwner {
  bool _current = false;

  @override
  bool get isCurrent => _current;

  void setCurrent(bool value) {
    if (_current == value) return;
    _current = value;
    notifyListeners();
  }
}

class _LocalNotificationRuntimeInherited
    extends InheritedNotifier<LocalNotificationRuntimeCoordinator> {
  const _LocalNotificationRuntimeInherited({
    required super.notifier,
    required super.child,
  });
}
