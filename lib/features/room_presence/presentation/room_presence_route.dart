import 'dart:async';
import 'dart:math';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../server/data/server_account_controller.dart';
import '../data/room_presence_management_api.dart';
import '../data/room_presence_management_controller.dart';
import '../data/room_presence_source_api.dart';
import 'room_presence_management_screen.dart';
import 'room_presence_source_screen.dart';

typedef RoomPresenceSourceApiFactory = RoomPresenceSourceApi Function(
  ServerAccountController account,
  bool Function() isCurrent,
);

final class RoomPresenceRoute extends ConsumerStatefulWidget {
  const RoomPresenceRoute({super.key, this.apiFactory, this.sourceApiFactory});

  final ServerApiFactory? apiFactory;
  final RoomPresenceSourceApiFactory? sourceApiFactory;

  @override
  ConsumerState<RoomPresenceRoute> createState() => _RoomPresenceRouteState();
}

final class _RoomPresenceRouteState extends ConsumerState<RoomPresenceRoute>
    with WidgetsBindingObserver {
  ProviderContainer? _container;
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _generation, _homeEpoch, _viewId;
  int _operation = 0;
  bool _closed = false, _scheduled = false, _foreground = true, _focused = true;
  bool _starting = false, _failed = false, _showSetup = false;
  CupertinoDialogRoute<void>? _confirmationRoute;
  final String _routeId = _id();
  RoomPresenceAccountGateway? _gateway;
  RoomPresenceManagementController? _controller;
  RoomPresenceSourceApi? _sourceApi;

  static String _id() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  bool _binding() {
    if (!mounted || _closed) return false;
    try {
      final home = _home;
      if (home == null ||
          !identical(
            ProviderScope.containerOf(context, listen: false),
            _container,
          ) ||
          !identical(ref.read(homeSessionControllerProvider), home) ||
          home.runtimeIdentity != _identity ||
          home.account.generation != _generation ||
          home.interaction.epoch != _homeEpoch) {
        _closed = true;
        return false;
      }
      return true;
    } catch (_) {
      _closed = true;
      return false;
    }
  }

  bool _window() {
    final state = ref.read(windowPolicySnapshotProvider);
    if (state.isLoading || state.hasError || !state.hasValue) return false;
    final value = state.requireValue;
    return !value.supported ||
        value.isResumed && value.hasWindowFocus && !value.isPictureInPicture;
  }

  bool _current() {
    if (!_binding()) return false;
    try {
      final home = _home!, session = home.account.session;
      final route = ModalRoute.of(context);
      return _foreground &&
          _focused &&
          _window() &&
          _interaction?.active == true &&
          home.source == HomeSource.verifiedCore &&
          !home.busy &&
          home.failure == null &&
          session?.context != null &&
          session!.user.mustChangePassword == false &&
          TickerMode.valuesOf(context).enabled &&
          (route?.isCurrent == true ||
              route?.isActive == true && _ownedConfirmationCurrent);
    } catch (_) {
      return false;
    }
  }

  bool _sourceCurrent() {
    if (!_showSetup || !_binding()) return false;
    try {
      final home = _home!, session = home.account.session;
      return _foreground &&
          _focused &&
          _window() &&
          _interaction?.active == true &&
          home.source == HomeSource.verifiedCore &&
          !home.busy &&
          home.failure == null &&
          session?.context != null &&
          session!.user.mustChangePassword == false &&
          session.user.canAdminister;
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
      if (_showSetup) {
        if (!_sourceCurrent()) {
          _sourceApi?.retire();
          _sourceApi = null;
          _showSetup = false;
          setState(() {});
        }
        return;
      }
      if (!_current()) {
        if (_controller != null || _gateway != null || _starting) {
          _disposeRuntime();
          setState(() {});
        }
        return;
      }
      if (_controller == null && !_starting && !_failed) {
        unawaited(_createRuntime());
      }
    });
  }

  void _setup() {
    if (!_current() || _home?.account.session?.user.canAdminister != true) {
      return;
    }
    _disposeRuntime();
    _showSetup = true;
    final factory = widget.sourceApiFactory;
    _sourceApi = factory == null
        ? AccountRoomPresenceSourceApi(
            account: _home!.account,
            isCurrent: _sourceCurrent,
          )
        : factory(_home!.account, _sourceCurrent);
    setState(() {});
  }

  Future<void> _finishSetup() async {
    _sourceApi?.retire();
    _sourceApi = null;
    if (!mounted) return;
    _showSetup = false;
    _failed = false;
    setState(() {});
    _schedule();
  }

  Future<void> _createRuntime() async {
    final operation = ++_operation;
    final home = _home!,
        session = home.account.session!,
        core = session.context!;
    final gateway = RoomPresenceAccountGateway(
      account: home.account,
      context: core,
      routeId: _routeId,
      routeRevision: 1,
      isCurrent: _current,
      apiFactory: widget.apiFactory,
    );
    _gateway = gateway;
    _starting = true;
    _failed = false;
    if (mounted) setState(() {});
    try {
      final authority = await gateway.bootstrap();
      if (!mounted || operation != _operation || !_current()) {
        gateway.close();
        return;
      }
      _controller = RoomPresenceManagementController(
        api: gateway,
        authority: authority,
        isCurrent: _current,
      );
    } catch (_) {
      if (mounted && operation == _operation) _failed = true;
      gateway.close();
      if (identical(_gateway, gateway)) _gateway = null;
    } finally {
      if (mounted && operation == _operation) {
        _starting = false;
        setState(() {});
      }
    }
  }

  void _disposeRuntime() {
    _operation++;
    final confirmation = _confirmationRoute;
    _confirmationRoute = null;
    if (confirmation?.isActive == true) {
      confirmation!.navigator?.removeRoute(confirmation);
    }
    _controller?.setInteractive(false);
    _controller?.dispose();
    _gateway?.close();
    _controller = null;
    _gateway = null;
    _starting = false;
  }

  bool get _ownedConfirmationCurrent {
    final confirmation = _confirmationRoute;
    if (confirmation?.isCurrent == true) return true;
    return confirmation?.isActive == true &&
        confirmation?.animation?.status == AnimationStatus.reverse;
  }

  void _confirmationRouteChanged(
    CupertinoDialogRoute<void> route,
    bool visible,
  ) {
    if (!mounted || _closed) return;
    if (visible) {
      if (_confirmationRoute != null && !identical(route, _confirmationRoute)) {
        return;
      }
      _confirmationRoute = route;
    } else {
      if (!identical(route, _confirmationRoute)) return;
      _confirmationRoute = null;
    }
    _schedule();
  }

  void _disposeSource() {
    _sourceApi?.retire();
    _sourceApi = null;
    _showSetup = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final container = ProviderScope.containerOf(context, listen: false);
    final interaction = AppInteractionScope.maybeOf(context);
    final view = View.of(context).viewId;
    if (_container == null) {
      _container = container;
      _home = ref.read(homeSessionControllerProvider);
      _identity = _home?.runtimeIdentity;
      _generation = _home?.account.generation;
      _homeEpoch = _home?.interaction.epoch;
      _home?.addListener(_changed);
    } else if (!identical(_container, container)) {
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
    if (_viewId != null && _viewId != view) {
      _closed = true;
      _focused = false;
    }
    _viewId = view;
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
    _changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _disposeSource();
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
    _disposeRuntime();
    _disposeSource();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    ref.listen(windowPolicySnapshotProvider, (_, _) => _changed());
    _schedule();
    final tr = Localizations.localeOf(context).languageCode == 'tr';
    final sourceApi = _sourceApi;
    if (_showSetup && sourceApi != null && _sourceCurrent()) {
      return RoomPresenceSourceScreen(
        api: sourceApi,
        strings: tr ? RoomPresenceSetupStrings.tr : RoomPresenceSetupStrings.en,
        onFinished: _finishSetup,
      );
    }
    final controller = _controller;
    if (controller != null && _current()) {
      return RoomPresenceManagementScreen(
        controller: controller,
        onConfirmationRouteChanged: _confirmationRouteChanged,
        setupLabel: tr
            ? RoomPresenceSetupStrings.tr.action
            : RoomPresenceSetupStrings.en.action,
        onSetup: _home?.account.session?.user.canAdminister == true
            ? _setup
            : null,
      );
    }
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(tr ? 'Oda varlığı' : 'Room presence'),
      ),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _failed
                        ? tr
                              ? 'Core oda varlığı doğrulanamadı.'
                              : 'Core room presence could not be verified.'
                        : tr
                        ? 'Core oda varlığı hazırlanıyor.'
                        : 'Preparing Core room presence.',
                    textAlign: TextAlign.center,
                  ),
                ),
                if (_failed) ...[
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: CupertinoButton.filled(
                      key: const ValueKey('room-presence-route-retry'),
                      onPressed: !_current()
                          ? null
                          : () {
                              setState(() => _failed = false);
                              _schedule();
                            },
                      child: Text(tr ? 'Tekrar dene' : 'Retry'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
