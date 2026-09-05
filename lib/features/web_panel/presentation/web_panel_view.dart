import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../data/web_panel_navigation_budget.dart';
import '../data/web_panel_platform.dart';
import '../data/web_panel_data.dart';
import '../domain/web_panel_options.dart';
import '../domain/web_panel_policy.dart';

enum _Failure { invalidUrl, blocked, timeout, load }

/// Shared bounded WebView lifetime. Origin checks are navigation policy, not a
/// firewall for POST, subresources, WebSockets or platform-internal requests.
class WebPanelView extends StatefulWidget {
  const WebPanelView({
    super.key,
    required this.policy,
    this.sourceIdentity,
    this.sourceCurrent,
    this.options,
    this.dataCoordinator,
  });
  final WebPanelPolicy? policy;
  final Object? sourceIdentity;
  final bool Function()? sourceCurrent;
  final WebPanelOptions? options;
  final WebPanelDataCoordinator? dataCoordinator;
  @override
  State<WebPanelView> createState() => WebPanelViewState();
}

class WebPanelViewState extends State<WebPanelView> {
  WebViewController? _controller;
  late final AppLifecycleListener _lifecycle;
  AppInteractionController? _interaction;
  ModalRoute<dynamic>? _route;
  int _generation = 0;
  bool _foreground = true, _visible = false, _ready = false;
  _Failure? _failure;
  Timer? _watchdog;
  final _sinceRestart = Stopwatch();
  bool _backBusy = false;
  late WebPanelDataCoordinator _data;

  @override
  void initState() {
    super.initState();
    _data = widget.dataCoordinator ?? WebPanelDataCoordinator.shared;
    _data.register(_clearRetire);
    _data.addListener(_dataChanged);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (!mounted) return;
        setState(() {
          _foreground = state == AppLifecycleState.resumed;
          _sync();
        });
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _visible = TickerMode.valuesOf(context).enabled;
    final interaction = AppInteractionScope.maybeOf(context);
    if (!identical(_interaction, interaction)) {
      _interaction?.removeListener(_interactionChanged);
      _interaction = interaction;
      _interaction?.addListener(_interactionChanged);
    }
    _sync();
  }

  void _interactionChanged() {
    if (mounted) setState(_sync);
  }

  @override
  void didUpdateWidget(covariant WebPanelView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final data = widget.dataCoordinator ?? WebPanelDataCoordinator.shared;
    if (!identical(_data, data)) {
      _data.unregister(_clearRetire);
      _data.removeListener(_dataChanged);
      _retire();
      _data = data;
      _data.register(_clearRetire);
      _data.addListener(_dataChanged);
    }
    if (oldWidget.policy != widget.policy ||
        oldWidget.sourceIdentity != widget.sourceIdentity ||
        oldWidget.options != widget.options) {
      _retire();
      _failure = null;
    }
    _sync();
  }

  bool get _active =>
      mounted &&
      _foreground &&
      _visible &&
      !_data.blocked &&
      (_interaction?.active ?? true) &&
      _route?.isCurrent != false &&
      (widget.sourceCurrent?.call() ?? true);
  bool _current(int generation) => _active && generation == _generation;

  void _dataChanged() {
    if (mounted) setState(_sync);
  }

  Future<void> _clearRetire() {
    _retire();
    return Future.value();
  }

  Future<void> _blankForClear(WebViewController controller) async {
    await controller.setJavaScriptMode(JavaScriptMode.disabled);
    await controller.loadHtmlString('<html></html>');
  }

  /// Invalidates callbacks immediately, before a parent account/idle rebuild.
  void suspend() {
    if (mounted) setState(_retire);
  }

  void restart() {
    if (!_active) return;
    if (_sinceRestart.isRunning &&
        _sinceRestart.elapsed < const Duration(seconds: 2)) {
      return;
    }
    _sinceRestart
      ..reset()
      ..start();
    setState(() {
      _retire();
      _failure = null;
      _sync();
    });
  }

  /// True means the back press was consumed. A cancelled old press must never
  /// pop an unrelated page underneath a newly pushed route.
  Future<bool> back() async {
    final generation = _generation;
    final controller = _controller;
    if (!_current(generation) || _backBusy) return true;
    if (controller == null) return false;
    _backBusy = true;
    try {
      final hasBack = await controller.canGoBack().timeout(
        const Duration(seconds: 5),
      );
      if (!_current(generation)) return true;
      if (!hasBack) return false;
      await controller.goBack().timeout(const Duration(seconds: 5));
      return true;
    } catch (_) {
      if (_current(generation)) _fail(_Failure.load, generation);
      return true;
    } finally {
      _backBusy = false;
    }
  }

  void _sync() {
    if (!_active) {
      _retire();
      return;
    }
    if (_controller != null || _failure != null) return;
    final policy = widget.policy;
    if (policy == null) {
      _failure = _Failure.invalidUrl;
      return;
    }
    final generation = ++_generation;
    try {
      final controller = createWebPanelController();
      _controller = controller;
      _ready = false;
      _watchdog?.cancel();
      _watchdog = Timer(
        const Duration(seconds: 30),
        () => _fail(_Failure.timeout, generation),
      );
      unawaited(_load(controller, policy, generation));
    } catch (_) {
      _failure = _Failure.load;
    }
  }

  Future<void> _load(
    WebViewController controller,
    WebPanelPolicy policy,
    int generation,
  ) async {
    Future<void> step(Future<void> Function() operation) async {
      if (!_current(generation)) throw const _Cancelled();
      await operation().timeout(const Duration(seconds: 5));
      if (!_current(generation)) throw const _Cancelled();
    }

    final budget = WebPanelNavigationBudget();
    try {
      await step(
        () => controller.setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) {
              if (!_current(generation)) return NavigationDecision.prevent;
              if (!policy.allows(request.url)) {
                _fail(_Failure.blocked, generation);
                return NavigationDecision.prevent;
              }
              if (!budget.take()) {
                _fail(_Failure.load, generation);
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            },
            onUrlChange: (change) {
              if (_current(generation) &&
                  change.url != null &&
                  !policy.allows(change.url!)) {
                _fail(_Failure.blocked, generation);
              }
            },
            onPageStarted: (url) {
              if (!_current(generation)) return;
              if (!policy.allows(url)) {
                _fail(_Failure.blocked, generation);
                return;
              }
              setState(() => _ready = false);
              // Redirects do not reset an existing deadline indefinitely.
              _watchdog ??= Timer(
                const Duration(seconds: 30),
                () => _fail(_Failure.timeout, generation),
              );
            },
            onPageFinished: (url) {
              if (!_current(generation)) return;
              if (!policy.allows(url)) {
                _fail(_Failure.blocked, generation);
                return;
              }
              _watchdog?.cancel();
              _watchdog = null;
              setState(() => _ready = true);
            },
            onWebResourceError: (error) {
              if (error.isForMainFrame != false) {
                _fail(_Failure.load, generation);
              }
            },
            onHttpAuthRequest: (request) =>
                unawaited(_ignore(request.onCancel)),
            onSslAuthError: (error) {
              unawaited(_ignore(error.cancel));
              _fail(_Failure.load, generation);
            },
          ),
        ),
      );
      await restrictWebPanelPlatform(controller, step);
      await configureWebPanelAppearance(controller, widget.options, step);
      await step(
        () => controller.setJavaScriptMode(JavaScriptMode.unrestricted),
      );
      await step(() => controller.loadRequest(policy.initialUri));
    } on _Cancelled {
      // A later account or route cannot inherit this controller.
    } on TimeoutException {
      _fail(_Failure.timeout, generation);
    } catch (_) {
      _fail(_Failure.load, generation);
    }
  }

  void _fail(_Failure failure, int generation) {
    if (!_current(generation)) return;
    setState(() {
      _failure = failure;
      _retire();
    });
  }

  void _retire() {
    _generation++;
    _watchdog?.cancel();
    _watchdog = null;
    final controller = _controller;
    _controller = null;
    _ready = false;
    if (controller != null) _data.retire(() => _blankForClear(controller));
  }

  static Future<void> _ignore(FutureOr<void> Function() operation) async {
    try {
      await Future<void>.sync(operation).timeout(const Duration(seconds: 5));
    } catch (_) {
      /* No raw website/platform messages or credentials. */
    }
  }

  @override
  void dispose() {
    _interaction?.removeListener(_interactionChanged);
    _data.unregister(_clearRetire);
    _data.removeListener(_dataChanged);
    _lifecycle.dispose();
    _retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_data.blocked) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(l10n.webPanelDataPaused, textAlign: TextAlign.center),
        ),
      );
    }
    if (!_active) return const SizedBox.shrink();
    if (_failure != null) {
      return Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(switch (_failure!) {
                  _Failure.invalidUrl => l10n.homeInvalidUrl,
                  _Failure.blocked => l10n.webPanelBlocked,
                  _Failure.timeout => l10n.webPanelTimedOut,
                  _Failure.load => l10n.webPanelLoadFailed,
                }, textAlign: TextAlign.center),
                CupertinoButton(
                  onPressed: restart,
                  child: Text(l10n.commonRetry),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return Stack(
      fit: StackFit.expand,
      children: [
        WebViewWidget(key: ValueKey(_generation), controller: controller),
        if (!_ready)
          const IgnorePointer(
            child: Center(child: CupertinoActivityIndicator()),
          ),
      ],
    );
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
