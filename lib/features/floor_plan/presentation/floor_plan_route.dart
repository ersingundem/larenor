import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../server/data/server_account_controller.dart';
import '../data/floor_plan_api.dart';
import '../data/floor_plan_controller.dart';
import 'floor_plan_screen.dart';

/// Owns one exact account/Core/home/route/lifecycle authority. Losing any part
/// closes transport and discards every late floor-plan response.
final class FloorPlanRoute extends ConsumerStatefulWidget {
  const FloorPlanRoute({super.key, this.apiFactory});
  final ServerApiFactory? apiFactory;

  @override
  ConsumerState<FloorPlanRoute> createState() => _FloorPlanRouteState();
}

final class _FloorPlanRouteState extends ConsumerState<FloorPlanRoute>
    with WidgetsBindingObserver {
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _generation, _homeEpoch;
  bool _foreground = true, _scheduled = false, _disposed = false;
  FloorPlanAccountGateway? _gateway;
  FloorPlanController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  bool _current() {
    if (!mounted || _disposed || !_foreground) return false;
    try {
      final home = _home;
      final session = home?.account.session;
      return home != null &&
          identical(ref.read(homeSessionControllerProvider), home) &&
          home.runtimeIdentity == _identity &&
          home.account.generation == _generation &&
          home.interaction.epoch == _homeEpoch &&
          _interaction?.active == true &&
          home.source == HomeSource.verifiedCore &&
          !home.busy &&
          home.failure == null &&
          session?.context != null &&
          session!.user.mustChangePassword == false &&
          TickerMode.valuesOf(context).enabled &&
          ModalRoute.of(context)?.isCurrent == true;
    } catch (_) {
      return false;
    }
  }

  void _changed() => _schedule();

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      if (!_current()) {
        if (_controller != null) {
          _closeRuntime();
          setState(() {});
        }
        return;
      }
      if (_controller == null) {
        final home = _home!;
        final context = home.account.session!.context!;
        late final FloorPlanAccountGateway gateway;
        gateway = FloorPlanAccountGateway(
          account: home.account,
          context: context,
          isCurrent: _current,
          apiFactory: widget.apiFactory,
        );
        final controller = FloorPlanController(
          gateway: gateway,
          isCurrent: _current,
        );
        _gateway = gateway;
        _controller = controller;
        unawaited(controller.load());
        setState(() {});
      }
    });
  }

  void _closeRuntime() {
    _controller?.retire();
    _controller?.dispose();
    _gateway?.close();
    _controller = null;
    _gateway = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final home = ref.read(homeSessionControllerProvider);
    final interaction = AppInteractionScope.maybeOf(context);
    if (_home == null) {
      _home = home;
      _identity = home?.runtimeIdentity;
      _generation = home?.account.generation;
      _homeEpoch = home?.interaction.epoch;
      home?.addListener(_changed);
    } else if (!identical(_home, home)) {
      _closeRuntime();
      _home?.removeListener(_changed);
      _home = home;
      _identity = home?.runtimeIdentity;
      _generation = home?.account.generation;
      _homeEpoch = home?.interaction.epoch;
      home?.addListener(_changed);
    }
    if (!identical(_interaction, interaction)) {
      _interaction?.removeListener(_changed);
      _interaction = interaction;
      interaction?.addListener(_changed);
    }
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_changed);
    _home?.removeListener(_changed);
    _closeRuntime();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    _schedule();
    final localizations = AppLocalizations.of(context);
    final strings = FloorPlanStrings.fromLocalizations(localizations);
    final controller = _controller;
    if (controller != null && _current()) {
      return FloorPlanScreen(controller: controller, strings: strings);
    }
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(strings.title)),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Semantics(
              liveRegion: true,
              child: Text(
                localizations.floorPlanRequired,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
