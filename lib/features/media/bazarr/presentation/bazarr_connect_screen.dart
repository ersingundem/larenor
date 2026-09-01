import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/discovery/lan_discovery_section.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../../data/media_api_exception.dart';
import '../providers/bazarr_providers.dart';

class BazarrConnectScreen extends ConsumerStatefulWidget {
  const BazarrConnectScreen({super.key});

  @override
  ConsumerState<BazarrConnectScreen> createState() =>
      _BazarrConnectScreenState();
}

class _BazarrConnectScreenState extends ConsumerState<BazarrConnectScreen> {
  final _urlController = TextEditingController(
    text: 'http://bazarr.local:6767',
  );
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
      await ref
          .read(bazarrConnectionProvider.notifier)
          .signIn(
            baseUrl: url.endsWith('/') ? url.substring(0, url.length - 1) : url,
            apiKey: key,
          );
      if (mounted) Navigator.of(context).pop();
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
      navigationBar: const CupertinoNavigationBar(middle: Text('Bazarr')),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 16),
                LanDiscoverySection(
                  signature: ServiceSignatures.bazarr,
                  onSelected: (url) =>
                      setState(() => _urlController.text = url),
                ),
                CupertinoListSection.insetGrouped(
                  footer: const Text(
                    'Find your API key in Bazarr under Settings → General.',
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
