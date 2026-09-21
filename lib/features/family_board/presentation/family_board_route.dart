import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../server/data/server_account_controller.dart';
import '../data/family_board_account_gateway.dart';
import '../data/family_board_cache.dart';
import '../data/family_board_controller.dart';
import '../domain/family_board_models.dart';
import 'family_board_screen.dart';

/// Owns one exact account/Core/home/route/lifecycle family-board authority.
final class FamilyBoardRoute extends ConsumerStatefulWidget {
  const FamilyBoardRoute({super.key, this.apiFactory});

  final ServerApiFactory? apiFactory;

  @override
  ConsumerState<FamilyBoardRoute> createState() => _FamilyBoardRouteState();
}

final class _FamilyBoardRouteState extends ConsumerState<FamilyBoardRoute>
    with WidgetsBindingObserver {
  ProviderContainer? _container;
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _accountGeneration, _homeEpoch, _viewId;
  final int _routeRevision = 1;
  int _lifecycleRevision = 1, _operation = 0;
  bool _foreground = true, _focused = true, _starting = false;
  String? _failure;
  FamilyBoardBinding? _binding;
  FamilyBoardAccountGateway? _gateway;
  FamilyBoardController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  bool _baseCurrent() {
    if (!mounted) return false;
    try {
      final home = _home;
      return home != null &&
          identical(
            ProviderScope.containerOf(context, listen: false),
            _container,
          ) &&
          identical(ref.read(homeSessionControllerProvider), home) &&
          home.runtimeIdentity == _identity &&
          home.account.generation == _accountGeneration &&
          home.interaction.epoch == _homeEpoch;
    } catch (_) {
      return false;
    }
  }

  bool _windowCurrent() {
    final state = ref.read(windowPolicySnapshotProvider);
    if (state.isLoading || state.hasError || !state.hasValue) return false;
    final value = state.requireValue;
    return !value.supported ||
        value.isResumed && value.hasWindowFocus && !value.isPictureInPicture;
  }

  bool _routeCurrent() {
    if (!_baseCurrent()) return false;
    try {
      final home = _home!, session = home.account.session;
      return _foreground &&
          _focused &&
          _windowCurrent() &&
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

  bool _bindingCurrent(FamilyBoardBinding value) =>
      _routeCurrent() &&
      identical(value, _binding) &&
      value.routeRevision == _routeRevision &&
      value.lifecycleRevision == _lifecycleRevision;

  void _changed() {
    if (!_routeCurrent()) {
      final visible = _controller != null || _starting;
      _retireRuntime();
      if (visible && mounted) setState(() {});
    } else {
      _start();
    }
  }

  void _start() {
    if (_starting || _controller != null || !_routeCurrent()) return;
    final operation = ++_operation;
    final home = _home!, session = home.account.session!;
    _starting = true;
    _failure = null;
    if (mounted) setState(() {});
    unawaited(() async {
      try {
        final binding = await FamilyBoardAccountGateway.loadBinding(
          account: home.account,
          context: session.context!,
          routeRevision: _routeRevision,
          lifecycleRevision: _lifecycleRevision,
          isCurrent: () => operation == _operation && _routeCurrent(),
          apiFactory: widget.apiFactory,
        );
        if (operation != _operation || !_routeCurrent()) return;
        late final FamilyBoardAccountGateway gateway;
        gateway = FamilyBoardAccountGateway(
          account: home.account,
          binding: binding,
          isCurrent: _bindingCurrent,
          apiFactory: widget.apiFactory,
        );
        final controller = FamilyBoardController(
          gateway: gateway,
          cache: SecureFamilyBoardCache(),
          binding: binding,
          isCurrent: _bindingCurrent,
        );
        _binding = binding;
        _gateway = gateway;
        _controller = controller;
        await controller.load();
        if (operation != _operation || !_bindingCurrent(binding)) {
          _retireRuntime();
          return;
        }
      } on FamilyBoardException catch (error) {
        if (operation == _operation) _failure = error.code;
      } catch (_) {
        if (operation == _operation) _failure = 'invalid_response';
      } finally {
        if (operation == _operation) {
          _starting = false;
          if (mounted) setState(() {});
        }
      }
    }());
  }

  void _retireRuntime() {
    _operation++;
    _starting = false;
    _binding = null;
    _controller?.retire();
    _controller?.dispose();
    _gateway?.close();
    _controller = null;
    _gateway = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final container = ProviderScope.containerOf(context, listen: false);
    final interaction = AppInteractionScope.maybeOf(context);
    final viewId = View.of(context).viewId;
    if (_container == null) {
      _container = container;
      _home = ref.read(homeSessionControllerProvider);
      _identity = _home?.runtimeIdentity;
      _accountGeneration = _home?.account.generation;
      _homeEpoch = _home?.interaction.epoch;
      _home?.addListener(_changed);
    }
    if (!identical(_container, container) ||
        _interaction != null && !identical(_interaction, interaction) ||
        _viewId != null && _viewId != viewId) {
      _retireRuntime();
      _focused = false;
    }
    if (!identical(_interaction, interaction)) {
      _interaction?.removeListener(_changed);
      _interaction = interaction;
      _interaction?.addListener(_changed);
    }
    _viewId = viewId;
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
    _changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _lifecycleRevision++;
    _retireRuntime();
    if (_foreground) _start();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    _focused = event.state == ViewFocusState.focused;
    if (!_focused) _retireRuntime();
    _changed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_changed);
    _home?.removeListener(_changed);
    _retireRuntime();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    ref.listen(windowPolicySnapshotProvider, (_, _) => _changed());
    final strings = FamilyBoardStrings.fromLocalizations(
      AppLocalizations.of(context),
    );
    final controller = _controller;
    if (controller != null && _bindingCurrent(controller.binding)) {
      return FamilyBoardScreen(controller: controller, strings: strings);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(strings.title)),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Semantics(
              liveRegion: true,
              child: _starting
                  ? const CupertinoActivityIndicator()
                  : Text(
                      _failure == null ? strings.loading : strings.unavailable,
                      textAlign: TextAlign.center,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
