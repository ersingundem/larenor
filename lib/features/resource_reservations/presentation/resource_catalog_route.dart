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
import '../../server/data/server_account_controller.dart';
import '../data/resource_reservation_api.dart';
import '../data/resource_catalog_controller.dart';
import 'resource_catalog_screen.dart';

/// Owns exactly one verified Core/account/home/route/window reservation runtime.
final class ResourceCatalogRoute extends ConsumerStatefulWidget {
  const ResourceCatalogRoute({super.key, this.apiFactory});

  final ServerApiFactory? apiFactory;

  @override
  ConsumerState<ResourceCatalogRoute> createState() =>
      _ResourceCatalogRouteState();
}

final class _ResourceCatalogRouteState
    extends ConsumerState<ResourceCatalogRoute>
    with WidgetsBindingObserver {
  ProviderContainer? _container;
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _generation, _homeEpoch, _viewId;
  int _operation = 0;
  bool _closed = false, _scheduled = false, _connecting = false;
  bool _foreground = true, _focused = true;
  ResourceReservationAccountApi? _api;
  ResourceCatalogController? _controller;

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
      return _foreground &&
          _focused &&
          _window() &&
          _interaction?.active == true &&
          home.source == HomeSource.verifiedCore &&
          !home.busy &&
          home.failure == null &&
          home.interaction.active &&
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
        if (_controller != null || _api != null || _connecting) {
          _retire();
          setState(() {});
        }
      } else if (_controller == null && !_connecting) {
        unawaited(_createRuntime());
      }
    });
  }

  Future<void> _createRuntime() async {
    final operation = ++_operation;
    _connecting = true;
    if (mounted) setState(() {});
    final home = _home!, context = home.account.session!.context!;
    try {
      final api = await ResourceReservationAccountApi.connect(
        account: home.account,
        context: context,
        routeId: _randomId(),
        isCurrent: () => operation == _operation && _current(),
        apiFactory: widget.apiFactory,
      );
      if (operation != _operation || !_current()) {
        api.close();
        return;
      }
      _api = api;
      _controller = ResourceCatalogController(api, commandIds: _randomId);
    } catch (_) {
      // The route stays read-only and exposes no stale retained state.
    } finally {
      if (operation == _operation) _connecting = false;
      if (mounted) setState(() {});
    }
  }

  void _retire() {
    _operation++;
    _connecting = false;
    final controller = _controller;
    _controller = null;
    controller?.retire();
    _api?.close();
    _api = null;
    if (controller != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }

  String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
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
    _retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    ref.listen(windowPolicySnapshotProvider, (_, _) => _changed());
    _schedule();
    final l10n = AppLocalizations.of(context);
    final controller = _controller, api = _api;
    if (controller != null && api != null && _current()) {
      return ResourceCatalogScreen(controller: controller);
    }
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.resourceCatalogTitle),
      ),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Semantics(
              liveRegion: true,
              child: Text(
                l10n.resourceCatalogAdminRequired,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
