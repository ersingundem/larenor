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
import '../data/epaper_account_api.dart';
import '../data/epaper_management_controller.dart';
import 'epaper_management_screen.dart';

/// Owns exactly one authenticated account/Core/home/route/window runtime.
final class EpaperManagementRoute extends ConsumerStatefulWidget {
  const EpaperManagementRoute({super.key, this.apiFactory});

  final ServerApiFactory? apiFactory;

  @override
  ConsumerState<EpaperManagementRoute> createState() =>
      _EpaperManagementRouteState();
}

final class _EpaperManagementRouteState
    extends ConsumerState<EpaperManagementRoute>
    with WidgetsBindingObserver {
  ProviderContainer? _container;
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _generation, _homeEpoch, _viewId;
  int _operation = 0;
  bool _closed = false, _scheduled = false, _connecting = false;
  bool _foreground = true, _focused = true;
  EpaperAccountApi? _api;
  EpaperManagementController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
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
    final snapshot = ref.read(windowPolicySnapshotProvider);
    if (snapshot.isLoading || snapshot.hasError || !snapshot.hasValue) {
      return false;
    }
    final value = snapshot.requireValue;
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
      final api = await EpaperAccountApi.connect(
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
      _controller = EpaperManagementController(
        api: api,
        authority: api.authority,
        isCurrent: () => operation == _operation && _current(),
      );
    } catch (_) {
      // No cached state is displayed after a failed authority handshake.
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
    controller?.setInteractive(false);
    _api?.close();
    _api = null;
    if (controller != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }

  static String _randomId() {
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
    final controller = _controller;
    if (controller != null && _current()) {
      return EpaperManagementScreen(controller: controller);
    }
    final l10n = AppLocalizations.of(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.settingsCategoryDisplay),
      ),
      child: SafeArea(
        child: Center(
          child: Semantics(
            liveRegion: true,
            label: l10n.homeCoreVerificationRequired,
            child: const CupertinoActivityIndicator(),
          ),
        ),
      ),
    );
  }
}
