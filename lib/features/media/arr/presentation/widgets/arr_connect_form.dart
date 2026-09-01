import 'package:flutter/cupertino.dart';

import '../../../../../shared/discovery/lan_discovery_section.dart';
import '../../../../../shared/discovery/lan_scanner.dart';
import '../../../data/media_api_exception.dart';

/// Shared connect UI for Sonarr/Radarr/Lidarr/Readarr — identical shape
/// (URL + API key), just parameterized by title/hint/the actual sign-in
/// call/discovery signature.
class ArrConnectForm extends StatefulWidget {
  const ArrConnectForm({
    super.key,
    required this.title,
    required this.urlHint,
    required this.onConnect,
    this.discoverySignature,
  });

  final String title;
  final String urlHint;
  final Future<void> Function(String baseUrl, String apiKey) onConnect;
  final LanServiceSignature? discoverySignature;

  @override
  State<ArrConnectForm> createState() => _ArrConnectFormState();
}

class _ArrConnectFormState extends State<ArrConnectForm> {
  late final _urlController = TextEditingController(text: widget.urlHint);
  final _keyController = TextEditingController();
  bool _connecting = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      setState(() => _error = 'Enter a server URL and API key.');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await widget.onConnect(
        url.endsWith('/') ? url.substring(0, url.length - 1) : url,
        key,
      );
    } on MediaApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not reach the server.');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(widget.title)),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 16),
                if (widget.discoverySignature != null)
                  LanDiscoverySection(
                    signature: widget.discoverySignature!,
                    onSelected: (url) =>
                        setState(() => _urlController.text = url),
                  ),
                CupertinoListSection.insetGrouped(
                  footer: Text(
                    'Find your API key in ${widget.title} under Settings → General → Security.',
                  ),
                  children: [
                    CupertinoTextFormFieldRow(
                      controller: _urlController,
                      prefix: const Text('URL'),
                      keyboardType: TextInputType.url,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _keyController,
                      prefix: const Text('API Key'),
                      obscureText: true,
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: CupertinoColors.systemRed.resolveFrom(context),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                CupertinoButton.filled(
                  onPressed: _connecting ? null : _connect,
                  child: _connecting
                      ? const CupertinoActivityIndicator(
                          color: CupertinoColors.white,
                        )
                      : const Text('Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
