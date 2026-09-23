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
import '../data/inventory_api.dart';
import '../data/inventory_controller.dart';
import '../data/inventory_scanner.dart';
import '../data/inventory_qr_share.dart';
import 'inventory_screen.dart';

/// Tablet route owning one exact home/session/window authority. Any authority,
/// container, lifecycle or view change retires all retained inventory evidence
/// and cancels the route-owned HTTP and camera work.
final class InventoryRoute extends ConsumerStatefulWidget {
  const InventoryRoute({
    super.key,
    this.apiFactory,
    this.scannerPlatform = const MobileInventoryScannerPlatform(),
    this.shareGateway,
  });

  final ServerApiFactory? apiFactory;
  final InventoryScannerPlatform scannerPlatform;
  final InventoryQrShareGateway? shareGateway;

  @override
  ConsumerState<InventoryRoute> createState() => _InventoryRouteState();
}

final class _InventoryRouteState extends ConsumerState<InventoryRoute>
    with WidgetsBindingObserver {
  ProviderContainer? _container;
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _generation, _homeEpoch, _viewId;
  bool _closed = false, _scheduled = false, _foreground = true, _focused = true;
  InventoryAccountGateway? _gateway;
  InventoryController? _controller;
  InventoryScannerController? _scanner;
  InventoryLabelShareController? _labelShare;

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

  void _changed() {
    _scanner?.synchronizeAuthority();
    _schedule();
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      if (!_current()) {
        if (_controller != null || _gateway != null || _scanner != null) {
          _disposeRuntime();
          setState(() {});
        }
        return;
      }
      if (_controller == null) {
        _createRuntime();
        setState(() {});
      }
    });
  }

  void _createRuntime() {
    final home = _home!,
        session = home.account.session!,
        context = session.context!;
    late final InventoryAccountGateway gateway;
    gateway = InventoryAccountGateway(
      account: home.account,
      context: context,
      apiFactory: widget.apiFactory,
      isCurrent: _current,
    );
    final controller = InventoryController(
      gateway: gateway,
      context: context,
      canReadGrants: session.user.canAdminister,
      isCurrent: _current,
    );
    final scanner = InventoryScannerController(
      platform: widget.scannerPlatform,
      isCurrent: _current,
      onValue: (value) {
        if (_current()) unawaited(controller.resolveScanned(value));
      },
    );
    final labelShare = InventoryLabelShareController(
      gateway: widget.shareGateway ?? InventoryQrShare(),
      sessionId: 'inventory-${session.user.id}',
      isCurrent: _current,
    );
    _gateway = gateway;
    _controller = controller;
    _scanner = scanner;
    _labelShare = labelShare;
  }

  void _disposeRuntime() {
    _scanner?.dispose();
    _labelShare?.retire();
    _labelShare?.dispose();
    _controller?.retire();
    _controller?.dispose();
    _gateway?.close();
    _scanner = null;
    _labelShare = null;
    _controller = null;
    _gateway = null;
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
    unawaited(_scanner?.onLifecycle(state));
    _changed();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    _focused = event.state == ViewFocusState.focused;
    _changed();
  }

  @override
  void didChangeMetrics() {
    unawaited(_scanner?.onRotation());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_changed);
    _home?.removeListener(_changed);
    _disposeRuntime();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    ref.listen(windowPolicySnapshotProvider, (_, _) => _changed());
    _schedule();
    final strings = InventoryStrings.fromLocalizations(
      AppLocalizations.of(context),
    );
    final controller = _controller, scanner = _scanner;
    if (controller != null && scanner != null && _current()) {
      return InventoryScreen(
        controller: controller,
        scanner: scanner,
        labelShare: _labelShare,
        strings: strings,
      );
    }
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(strings.title)),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Semantics(
              liveRegion: true,
              child: Text(strings.required, textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}
