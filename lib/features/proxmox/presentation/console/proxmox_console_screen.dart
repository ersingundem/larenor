import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../data/models/proxmox_guest.dart';
import '../../providers/proxmox_providers.dart';

/// Uses the console client served by this Proxmox version. Its noVNC/xterm
/// page handles console tickets, terminal framing, resizing and reconnects on
/// the same origin as the authenticated API, including self-signed servers.
class ProxmoxConsoleScreen extends ConsumerStatefulWidget {
  const ProxmoxConsoleScreen({super.key, required this.guest});

  final ProxmoxGuest guest;

  @override
  ConsumerState<ProxmoxConsoleScreen> createState() =>
      _ProxmoxConsoleScreenState();
}

class _ProxmoxConsoleScreenState extends ConsumerState<ProxmoxConsoleScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    _prepare();
  }

  Future<void> _prepare() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final client = await ref.read(proxmoxClientProvider.future);
      if (!mounted) return;
      if (client == null) {
        setState(
          () =>
              _error = AppLocalizations.of(context).proxmoxConsoleNotConnected,
        );
        return;
      }
      await client.ensureAuthenticated();
      if (!mounted) return;
      final page = client.consolePageUrl(widget.guest);
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _controller.setBackgroundColor(const Color(0xFF000000));
      await _controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final target = Uri.tryParse(request.url);
            final sameServer =
                target != null &&
                {'http', 'https'}.contains(target.scheme) &&
                target.hasAuthority &&
                target.origin == page.origin;
            return sameServer
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() {
                _error = error.description;
                _loading = false;
              });
            }
          },
          onSslAuthError: (error) {
            if (client.config.allowSelfSigned) {
              error.proceed();
            } else {
              error.cancel();
            }
          },
        ),
      );
      await WebViewCookieManager().setCookie(
        WebViewCookie(
          name: 'PVEAuthCookie',
          value: client.authCookieValue,
          domain: client.config.host,
          path: '/',
        ),
      );
      if (!mounted) return;
      await _controller.loadRequest(page);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = AppLocalizations.of(context)
              .proxmoxConsoleOpenError(error.toString());
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the API client alive for the life of its console session.
    ref.watch(proxmoxClientProvider);
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFF000000),
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          AppLocalizations.of(context).proxmoxConsoleTitle(widget.guest.name),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _loading ? null : _prepare,
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_loading && _error == null)
              const Center(
                child: CupertinoActivityIndicator(color: CupertinoColors.white),
              ),
            if (_error != null)
              ColoredBox(
                color: const Color(0xFF000000),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: CupertinoColors.white),
                        ),
                        CupertinoButton(
                          onPressed: _prepare,
                          child: Text(AppLocalizations.of(context).commonRetry),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
