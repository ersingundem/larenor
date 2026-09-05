import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../domain/dashboard_website_url.dart';
import '../../domain/tile_config.dart';

/// An explicitly configured website. No HA credentials or native JS bridge are
/// injected. Hidden/background cards retire their page and its active scripts.
class WebviewTile extends StatefulWidget {
  const WebviewTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  State<WebviewTile> createState() => _WebviewTileState();
}

class _WebviewTileState extends State<WebviewTile> {
  WebViewController? _controller;
  late final AppLifecycleListener _lifecycle;
  int _generation = 0;
  bool _foreground = true, _visible = false, _failed = false, _ready = false;

  @override
  void initState() {
    super.initState();
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
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(covariant WebviewTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tile.url != widget.tile.url) {
      _retire();
      _failed = false;
      _sync();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _retire();
    super.dispose();
  }

  bool _current(int generation) =>
      mounted && _foreground && _visible && generation == _generation;
  void _sync() {
    if (!_foreground || !_visible) {
      _retire();
      return;
    }
    if (_controller != null || _failed) return;
    final url = dashboardWebsiteUrl(widget.tile.url ?? '');
    if (url == null) {
      _failed = true;
      return;
    }
    final generation = ++_generation;
    try {
      final controller = WebViewController(
        onPermissionRequest: (request) {
          // Website camera/microphone permissions belong to the later explicit
          // kiosk policy; a dashboard card cannot grant them on the user's behalf.
          unawaited(_ignoreFailure(request.deny));
        },
      );
      _controller = controller;
      _ready = false;
      unawaited(_load(controller, Uri.parse(url), generation));
    } catch (_) {
      _failed = true;
    }
  }

  Future<void> _load(
    WebViewController controller,
    Uri url,
    int generation,
  ) async {
    void fail() {
      if (_current(generation)) {
        setState(() {
          _failed = true;
          _retire();
        });
      }
    }

    try {
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              _current(generation) && dashboardWebsiteUrl(request.url) != null
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageStarted: (_) {
            if (_current(generation)) setState(() => _ready = false);
          },
          onPageFinished: (_) {
            if (_current(generation)) setState(() => _ready = true);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame != false) fail();
          },
          onHttpAuthRequest: (request) {
            unawaited(_ignoreFailure(request.onCancel));
          },
          onSslAuthError: (error) {
            unawaited(_ignoreFailure(error.cancel));
            fail();
          },
        ),
      );
      if (!_current(generation)) return;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!_current(generation)) return;
      await controller.loadRequest(url);
    } catch (_) {
      fail();
    }
  }

  void _retire() {
    _generation++;
    final controller = _controller;
    _controller = null;
    _ready = false;
    if (controller != null) unawaited(_blank(controller));
  }

  Future<void> _blank(WebViewController controller) async {
    await _ignoreFailure(
      () => controller.setJavaScriptMode(JavaScriptMode.disabled),
    );
    await _ignoreFailure(() => controller.loadHtmlString('<html></html>'));
  }

  static Future<void> _ignoreFailure(
    FutureOr<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (_) {
      /* No raw server/platform data in UI/logs. */
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_failed) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                dashboardWebsiteUrl(widget.tile.url ?? '') == null
                    ? l10n.homeInvalidUrl
                    : l10n.commonError,
                textAlign: TextAlign.center,
              ),
              CupertinoButton(
                onPressed: !_foreground || !_visible
                    ? null
                    : () {
                        setState(() {
                          _failed = false;
                          _sync();
                        });
                      },
                child: Text(l10n.commonRetry),
              ),
            ],
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
