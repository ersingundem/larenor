import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../auth/providers/auth_providers.dart';

/// The official frontend supplies server-specific panels and features for
/// which Larenor has no native screen yet. It owns its own login session: the
/// long-lived API credential is never injected into browser scripts/storage.
class HaFrontendScreen extends ConsumerStatefulWidget {
  const HaFrontendScreen({super.key});
  @override
  ConsumerState<HaFrontendScreen> createState() => _HaFrontendScreenState();
}

class _HaFrontendScreenState extends ConsumerState<HaFrontendScreen> {
  WebViewController? _controller;
  String? _error;
  int _progress = 0;
  @override
  void initState() {
    super.initState();
    final config = ref.read(connectionConfigProvider).value;
    if (config == null) return;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _error = null);
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return uri != null &&
                    {'http', 'https', 'about'}.contains(uri.scheme)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame == true) {
              setState(() => _error = error.description);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(config.baseUrl));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = _controller;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.haFrontend),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () async {
            if (controller != null && await controller.canGoBack()) {
              await controller.goBack();
            } else if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: Semantics(
            label: l10n.commonBack,
            child: const Icon(CupertinoIcons.back),
          ),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: controller?.reload,
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: controller == null
            ? Center(child: Text(l10n.haDisconnected))
            : Column(
                children: [
                  if (_progress < 100)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: CupertinoActivityIndicator(),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!),
                    ),
                  Expanded(child: WebViewWidget(controller: controller)),
                ],
              ),
      ),
    );
  }
}
