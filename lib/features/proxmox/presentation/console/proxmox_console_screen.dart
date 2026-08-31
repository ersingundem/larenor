import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/models/proxmox_guest.dart';
import '../../providers/proxmox_providers.dart';

/// Embeds an interactive console for a VM (noVNC) or container (xterm.js)
/// inside a WebView, loading vendored client-side JS bundled as Flutter
/// assets. The console websocket needs both a vnc/term ticket (as a query
/// param) *and* Proxmox's `PVEAuthCookie` present on the connection, so
/// the cookie is pushed into the WebView's cookie jar before the page
/// loads.
class ProxmoxConsoleScreen extends ConsumerStatefulWidget {
  const ProxmoxConsoleScreen({super.key, required this.guest});

  final ProxmoxGuest guest;

  @override
  ConsumerState<ProxmoxConsoleScreen> createState() =>
      _ProxmoxConsoleScreenState();
}

class _ProxmoxConsoleScreenState extends ConsumerState<ProxmoxConsoleScreen> {
  late final WebViewController _controller;
  String? _wsUrl;
  bool _connecting = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..setNavigationDelegate(
        NavigationDelegate(onPageFinished: (_) => _connect()),
      );
    _prepare();
  }

  Future<void> _prepare() async {
    final client = ref.read(proxmoxClientProvider).value;
    if (client == null) {
      setState(() => _error = 'Not connected.');
      return;
    }

    try {
      final isQemu = widget.guest.type == ProxmoxGuestType.qemu;
      final ticket = isQemu
          ? await client.vncTicket(widget.guest.node, widget.guest.vmid)
          : await client.termTicket(widget.guest.node, widget.guest.vmid);
      _wsUrl = client.consoleWebSocketUrl(
        node: widget.guest.node,
        console: ticket,
      );

      await WebViewCookieManager().setCookie(
        WebViewCookie(
          name: 'PVEAuthCookie',
          value: client.authCookieValue,
          domain: client.config.host,
        ),
      );

      final asset = isQemu
          ? 'assets/console/novnc.html'
          : 'assets/console/xterm.html';
      await _controller.loadFlutterAsset(asset);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open console: $e');
    }
  }

  Future<void> _connect() async {
    final url = _wsUrl;
    if (url == null || _connecting) return;
    _connecting = true;

    for (var attempt = 0; attempt < 15; attempt++) {
      final ready = await _controller.runJavaScriptReturningResult(
        'typeof window.larenorConnect === "function"',
      );
      if ('$ready' == 'true') break;
      await Future.delayed(const Duration(milliseconds: 200));
    }

    await _controller.runJavaScript(
      'window.larenorConnect(${jsonEncode(url)});',
    );
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text('${widget.guest.name} — Console'),
      ),
      child: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading && _error == null)
            const Center(
              child: CupertinoActivityIndicator(color: CupertinoColors.white),
            ),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: CupertinoColors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
