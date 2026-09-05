import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../dashboard/domain/dashboard_website_url.dart';
import '../../data/models/proxmox_guest.dart';
import '../../providers/proxmox_providers.dart';
import '../proxmox_session_guard.dart';

/// The server's own console/login page, with its normal web authentication.
/// Native API cookies, passwords and tickets are never copied to WebView's
/// process-wide browser cookie store. Web TLS errors always cancel.
class ProxmoxConsoleScreen extends ConsumerStatefulWidget {
  const ProxmoxConsoleScreen({
    super.key,
    required this.guest,
    this.sourceCurrent,
  });
  final ProxmoxGuest guest;
  final bool Function()? sourceCurrent;
  @override
  ConsumerState<ProxmoxConsoleScreen> createState() =>
      _ProxmoxConsoleScreenState();
}

class _ProxmoxConsoleScreenState
    extends ProxmoxSessionState<ProxmoxConsoleScreen> {
  @override
  bool sourceSessionCurrent() => widget.sourceCurrent?.call() ?? true;

  WebViewController? _controller;
  bool _loading = false, _preparing = false, _scheduled = false;
  bool _visible = false, _targetChanged = false;
  bool _webSignIn = true;
  int _pageGeneration = 0;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    if (!_visible) _retire();
  }

  @override
  void didUpdateWidget(covariant ProxmoxConsoleScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.guest.node != widget.guest.node ||
        oldWidget.guest.type != widget.guest.type ||
        oldWidget.guest.vmid != widget.guest.vmid) {
      _targetChanged = true;
      _retire();
    }
  }

  @override
  void onSessionInvalidated() {
    _retire();
    _error = null;
  }

  bool _current(ProxmoxSessionLease lease, int generation) =>
      !_targetChanged &&
      _visible &&
      generation == _pageGeneration &&
      isSessionCurrent(lease);

  void _schedule() {
    if (_scheduled ||
        _preparing ||
        _controller != null ||
        _error != null ||
        !sessionAvailable ||
        !_visible ||
        _targetChanged) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_prepare());
    });
  }

  void _selectPage(bool webSignIn) {
    if (!sessionAvailable ||
        !_visible ||
        _targetChanged ||
        _preparing ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    _webSignIn = webSignIn;
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    if (!sessionAvailable ||
        !_visible ||
        _targetChanged ||
        _preparing ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    _retire();
    final generation = ++_pageGeneration;
    setState(() {
      _preparing = true;
      _loading = true;
      _error = null;
    });
    try {
      final lease = await readSessionClient();
      if (lease == null || !_current(lease, generation)) return;
      // Console-only templates do not provide the full web login dialog.
      // Start on the ordinary interface and let the user explicitly continue
      // after their independent browser session has signed in.
      final page = _webSignIn
          ? Uri.parse(lease.client.config.baseUrl).replace(path: '/')
          : lease.client.consolePageUrl(widget.guest);
      if (dashboardWebsiteUrl(page.toString()) == null ||
          page.scheme != 'https') {
        throw const FormatException('Invalid console origin');
      }
      void fail({bool tls = false}) {
        if (!_current(lease, generation)) return;
        setState(() {
          _error = tls
              ? AppLocalizations.of(context).proxmoxConsoleTrustedTlsRequired
              : AppLocalizations.of(context).commonError;
          _retire();
        });
      }

      final controller = WebViewController(
        onPermissionRequest: (request) => unawaited(_ignore(request.deny)),
      );
      _controller = controller;
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (!_current(lease, generation)) return NavigationDecision.prevent;
            final safe = dashboardWebsiteUrl(request.url);
            final target = safe == null ? null : Uri.tryParse(safe);
            return target?.origin == page.origin
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageStarted: (_) {
            if (_current(lease, generation)) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (_current(lease, generation)) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame != false) fail();
          },
          onHttpAuthRequest: (request) => unawaited(_ignore(request.onCancel)),
          onSslAuthError: (error) {
            // The portable callback exposes no request URL; a server-specific API
            // TLS exception cannot safely authorize arbitrary browser resources.
            unawaited(_ignore(error.cancel));
            fail(tls: true);
          },
        ),
      );
      if (!_current(lease, generation)) return;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!_current(lease, generation)) return;
      await controller.setBackgroundColor(const Color(0xFF000000));
      if (!_current(lease, generation)) return;
      await controller.loadRequest(page);
    } catch (_) {
      if (mounted && generation == _pageGeneration && sessionAvailable) {
        setState(() {
          _error = AppLocalizations.of(context).commonError;
          _retire();
        });
      }
    } finally {
      if (mounted && generation == _pageGeneration) {
        setState(() => _preparing = false);
      }
    }
  }

  void _retire() {
    _pageGeneration++;
    _preparing = false;
    _loading = false;
    final controller = _controller;
    _controller = null;
    if (controller != null) unawaited(_blank(controller));
  }

  Future<void> _blank(WebViewController controller) async {
    await _ignore(() => controller.setJavaScriptMode(JavaScriptMode.disabled));
    await _ignore(() => controller.loadHtmlString('<html></html>'));
  }

  static Future<void> _ignore(FutureOr<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {
      /* Never display platform details. */
    }
  }

  @override
  void dispose() {
    _retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchProxmoxSession();
    if (sessionAvailable && _visible && !_targetChanged) {
      ref.watch(proxmoxClientProvider);
    }
    _schedule();
    final l10n = AppLocalizations.of(context);
    final available = sessionAvailable && !_targetChanged;
    final controller = _controller;
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFF000000),
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.proxmoxConsoleTitle(widget.guest.name)),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: !available || !_visible || _preparing ? null : _prepare,
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                l10n.proxmoxConsoleSignInRequired,
                style: const TextStyle(color: CupertinoColors.white),
              ),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                CupertinoButton(
                  onPressed: !available || !_visible || _preparing
                      ? null
                      : () => _selectPage(true),
                  child: Text(l10n.proxmoxConsoleWebSignIn),
                ),
                CupertinoButton(
                  onPressed: !available || !_visible || _preparing
                      ? null
                      : () => _selectPage(false),
                  child: Text(l10n.proxmoxConsoleOpenSession),
                ),
              ],
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (available && _visible && controller != null)
                    WebViewWidget(
                      key: ValueKey(_pageGeneration),
                      controller: controller,
                    ),
                  if (_loading && available && _error == null)
                    const Center(
                      child: CupertinoActivityIndicator(
                        color: CupertinoColors.white,
                      ),
                    ),
                  if (!available || _error != null)
                    Center(
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            !available ? l10n.proxmoxSessionExpired : _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: CupertinoColors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
