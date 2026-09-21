import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../server/domain/server_models.dart';
import '../data/camera_search_api.dart';
import '../data/camera_search_controller.dart';
import '../domain/camera_search_models.dart';
import 'camera_search_screen.dart';

/// Route-owned F41 binding. Results cannot outlive the exact Core account,
/// home, session, window, route or index revision used to discover them.
final class CameraSearchRoute extends ConsumerStatefulWidget {
  const CameraSearchRoute({super.key, this.clock});

  final DateTime Function()? clock;

  @override
  ConsumerState<CameraSearchRoute> createState() => _CameraSearchRouteState();
}

final class _CameraSearchRouteState extends ConsumerState<CameraSearchRoute>
    with WidgetsBindingObserver {
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _runtimeIdentity;
  int? _accountGeneration, _interactionEpoch, _viewId;
  ServerSession? _session;
  CameraSearchApi? _api;
  CameraSearchController? _controller;
  CameraSearchContext? _context;
  bool _loading = false,
      _scheduled = false,
      _foreground = true,
      _focused = true;
  String? _failure;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  bool _binding() {
    final home = _home;
    if (!mounted || home == null) return false;
    try {
      return identical(ref.read(homeSessionControllerProvider), home) &&
          home.runtimeIdentity == _runtimeIdentity &&
          home.account.generation == _accountGeneration &&
          home.source == HomeSource.verifiedCore &&
          !home.busy &&
          home.failure == null;
    } catch (_) {
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

  bool _currentFor(ServerSession? session) {
    if (!_binding() || session == null) return false;
    try {
      final active = _home!.account.session;
      return identical(active, session) &&
          active?.context != null &&
          active!.user.mustChangePassword == false &&
          _foreground &&
          _focused &&
          _window() &&
          (_interaction?.active ?? true) &&
          _interaction?.epoch == _interactionEpoch &&
          TickerMode.valuesOf(context).enabled &&
          ModalRoute.of(context)?.isCurrent == true;
    } catch (_) {
      return false;
    }
  }

  bool get _current => _currentFor(_session);

  void _retireRuntime() {
    _api?.retire();
    _controller?.retire();
    _api = null;
    _controller = null;
    _context = null;
    _filter = null;
    _session = null;
  }

  void _changed() {
    if (!mounted) return;
    if (_session != null && !_current) {
      _retireRuntime();
      _failure = null;
    }
    _schedule();
    setState(() {});
  }

  void _schedule() {
    if (_scheduled || _loading || _controller != null || _failure != null) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted && _binding()) unawaited(_load());
    });
  }

  Future<void> _load() async {
    if (_loading || !_binding()) return;
    _loading = true;
    _failure = null;
    if (mounted) setState(() {});
    CameraSearchApi? pending;
    try {
      final account = _home!.account;
      final loaded = await account.withSession((serverApi, session) async {
        _session = session;
        if (!_currentFor(session)) {
          throw const LarenorServerException('cancelled');
        }
        final api = CameraSearchApi(
          serverApi,
          session,
          isCurrent: () => _currentFor(session),
        );
        pending = api;
        final context = await api.loadContext();
        if (!_currentFor(session) ||
            context.coreId != session.context!.coreId ||
            context.homeId != session.context!.homeId) {
          throw const LarenorServerException('cancelled');
        }
        return (api: api, session: session, context: context);
      });
      if (!_currentFor(loaded.session)) {
        loaded.api.retire();
        return;
      }
      final now = (widget.clock ?? DateTime.now)().toUtc();
      _api = loaded.api;
      _session = loaded.session;
      _context = loaded.context;
      _controller = CameraSearchController(
        gateway: loaded.api,
        isCurrent: () => _currentFor(loaded.session),
      );
      pending = null;
      _failure = null;
      // The exact bounded window is created once for this route authority.
      _filter = CameraSearchFilter(
        expectedIndexRevision: loaded.context.indexRevision,
        start: now.subtract(const Duration(days: 1)),
        end: now,
        cameraIds: loaded.context.cameraIds.take(16).toList(growable: false),
      );
    } catch (_) {
      pending?.retire();
      _retireRuntime();
      if (_binding()) _failure = 'unavailable';
    } finally {
      _loading = false;
      if (mounted) setState(() {});
    }
  }

  CameraSearchFilter? _filter;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final home = ref.read(homeSessionControllerProvider);
    final interaction = AppInteractionScope.maybeOf(context);
    final viewId = View.of(context).viewId;
    if (_home == null) {
      _home = home;
      _runtimeIdentity = home?.runtimeIdentity;
      _accountGeneration = home?.account.generation;
      home?.addListener(_changed);
    } else if (!identical(_home, home)) {
      _retireRuntime();
      _failure = 'unavailable';
    }
    if (!identical(_interaction, interaction)) {
      _interaction?.removeListener(_changed);
      _interaction = interaction;
      _interactionEpoch = interaction?.epoch;
      interaction?.addListener(_changed);
    }
    if (_viewId != null && _viewId != viewId) {
      _focused = false;
      _retireRuntime();
    }
    _viewId = viewId;
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _retireRuntime();
    _changed();
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
    final strings = CameraSearchStrings.fromLocalizations(
      AppLocalizations.of(context),
    );
    final controller = _controller, filter = _filter, searchContext = _context;
    if (controller != null &&
        filter != null &&
        searchContext != null &&
        _current) {
      return CameraSearchScreen(
        controller: controller,
        strings: strings,
        filter: filter,
        cameraNames: {
          for (var index = 0; index < searchContext.cameraIds.length; index++)
            searchContext.cameraIds[index]: '${strings.camera} ${index + 1}',
        },
      );
    }
    _schedule();
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(strings.title)),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Semantics(
              liveRegion: true,
              child: _loading
                  ? const CupertinoActivityIndicator()
                  : Text(
                      _failure == null
                          ? strings.requiredMessage
                          : strings.unavailable,
                      textAlign: TextAlign.center,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
