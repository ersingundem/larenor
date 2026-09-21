import 'dart:math';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../home_resources/data/core_bounded_upload_file_access.dart';
import '../../server/data/server_account_controller.dart';
import '../data/home_document_api.dart';
import '../data/home_document_controller.dart';
import 'home_documents_screen.dart';

final class HomeDocumentsRoute extends ConsumerStatefulWidget {
  const HomeDocumentsRoute({
    super.key,
    this.apiFactory,
    this.boundedApiFactory,
    this.fileAccess,
  });

  final ServerApiFactory? apiFactory;
  final HomeDocumentBoundedApiFactory? boundedApiFactory;
  final CoreBoundedUploadFileAccess? fileAccess;

  @override
  ConsumerState<HomeDocumentsRoute> createState() => _HomeDocumentsRouteState();
}

final class _HomeDocumentsRouteState extends ConsumerState<HomeDocumentsRoute>
    with WidgetsBindingObserver {
  ProviderContainer? _container;
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _generation, _homeEpoch, _viewId;
  bool _closed = false, _scheduled = false, _foreground = true, _focused = true;
  HomeDocumentAccountGateway? _gateway;
  HomeDocumentController? _controller;

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
        if (_controller != null || _gateway != null) {
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

  static String _id() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _createRuntime() {
    final home = _home!,
        session = home.account.session!,
        context = session.context!;
    final gateway = HomeDocumentAccountGateway(
      account: home.account,
      context: context,
      isCurrent: _current,
      files: widget.fileAccess ?? ref.read(coreBoundedUploadFileAccessProvider),
      apiFactory: widget.apiFactory,
      boundedApiFactory: widget.boundedApiFactory,
    );
    _gateway = gateway;
    _controller = HomeDocumentController(
      gateway: gateway,
      context: context,
      accountId: session.user.id,
      isAdmin: session.user.canAdminister,
      isCurrent: _current,
      requestIdFactory: _id,
      documentIdFactory: _id,
    );
  }

  void _disposeRuntime() {
    _controller?.setActive(false);
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
    _disposeRuntime();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    ref.listen(windowPolicySnapshotProvider, (_, _) => _changed());
    _schedule();
    final controller = _controller;
    if (controller != null && _current()) {
      return HomeDocumentsScreen(controller: controller);
    }
    final l10n = AppLocalizations.of(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.inventoryDocuments),
      ),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Semantics(
              liveRegion: true,
              child: Text(l10n.inventoryRequired, textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}
