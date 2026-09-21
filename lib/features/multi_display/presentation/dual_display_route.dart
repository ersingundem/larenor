import 'dart:async';
import 'dart:math';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../data/dual_display_platform_port.dart';
import '../data/dual_display_task_controller.dart';
import '../domain/dual_display_session.dart';
import 'dual_display_task_screen.dart';

/// Owns the display lease for one exact account, home, route and window.
class DualDisplayRoute extends ConsumerStatefulWidget {
  const DualDisplayRoute({super.key, this.platform});

  final DualDisplayPlatformPort? platform;

  @override
  ConsumerState<DualDisplayRoute> createState() => _DualDisplayRouteState();
}

class _DualDisplayRouteState extends ConsumerState<DualDisplayRoute>
    with WidgetsBindingObserver {
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  DualDisplayTaskController? _controller;
  Object? _identity;
  int? _accountGeneration, _homeEpoch, _viewId;
  bool _foreground = true, _focused = true, _closed = false, _scheduled = false;
  late final String _displaySessionId = _randomIdentity();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  bool _bindingCurrent() {
    final home = _home;
    return mounted &&
        !_closed &&
        home != null &&
        identical(ref.read(homeSessionControllerProvider), home) &&
        home.runtimeIdentity == _identity &&
        home.account.generation == _accountGeneration &&
        home.interaction.epoch == _homeEpoch;
  }

  bool _windowCurrent() {
    final reading = ref.read(windowPolicySnapshotProvider);
    if (reading.isLoading || reading.hasError || !reading.hasValue) {
      return false;
    }
    final window = reading.requireValue;
    return !window.supported ||
        window.isResumed && window.hasWindowFocus && !window.isPictureInPicture;
  }

  bool _current() {
    if (!_bindingCurrent()) return false;
    final home = _home!, session = home.account.session;
    return _foreground &&
        _focused &&
        _windowCurrent() &&
        _interaction?.active != false &&
        home.source == HomeSource.verifiedCore &&
        session?.context != null &&
        session!.user.mustChangePassword == false &&
        RegExp(r'^[0-9a-f]{32}$').hasMatch(session.user.id) &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent == true;
  }

  DisplayRouteAuthority _authority() {
    final home = _home!, account = home.account, session = account.session!;
    return DisplayRouteAuthority(
      accountId: session.user.id,
      accountRevision: account.generation + 1,
      homeId: session.context!.homeId,
      homeRevision: account.generation + 1,
      sessionFamilyId: _displaySessionId,
      routeRevision: 1,
      lifecycleEpoch: (_homeEpoch ?? 0) + 1,
      interactionEpoch: home.interaction.epoch + 1,
      allowedSecondaryRoutes: const {'dashboard.overview', 'media.now-playing'},
    );
  }

  void _changed() {
    _schedule();
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      if (!_current()) {
        if (_controller != null) {
          _disposeRuntime(rebuild: false);
          setState(() {});
        }
      } else if (_controller == null) {
        final controller = DualDisplayTaskController(
          widget.platform ?? const MethodChannelSecondaryDisplayPort(),
          _authority,
          _current,
        );
        setState(() => _controller = controller);
        unawaited(controller.refresh());
      }
    });
  }

  void _disposeRuntime({bool rebuild = true}) {
    final controller = _controller;
    if (controller == null) return;
    _controller = null;
    controller.retire();
    controller.dispose();
    if (mounted && rebuild) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final home = ref.read(homeSessionControllerProvider);
    final interaction = AppInteractionScope.maybeOf(context);
    final viewId = View.of(context).viewId;
    if (_home == null) {
      _home = home;
      _identity = home?.runtimeIdentity;
      _accountGeneration = home?.account.generation;
      _homeEpoch = home?.interaction.epoch;
      home?.addListener(_changed);
    } else if (!identical(_home, home)) {
      _closed = true;
    }
    if (_interaction != null && !identical(_interaction, interaction)) {
      _closed = true;
    }
    if (!identical(_interaction, interaction)) {
      _interaction?.removeListener(_changed);
      _interaction = interaction;
      interaction?.addListener(_changed);
    }
    if (_viewId != null && _viewId != viewId) _closed = true;
    _viewId = viewId;
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
    _changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _changed();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    _focused = event.state == ViewFocusState.focused;
    _changed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_changed);
    _home?.removeListener(_changed);
    _disposeRuntime(rebuild: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    ref.listen(windowPolicySnapshotProvider, (_, _) => _changed());
    _schedule();
    final controller = _controller;
    if (controller != null) {
      return DualDisplayTaskScreen(controller: controller);
    }
    final l10n = AppLocalizations.of(context);
    return ServiceRootScaffold(
      title: l10n.dualDisplayTitle,
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.dualDisplayUnavailable),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _randomIdentity() {
    final random = Random.secure();
    const digits = '0123456789abcdef';
    return List.generate(32, (_) => digits[random.nextInt(16)]).join();
  }
}
