import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/discovery/lan_discovery_section.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../../data/media_api_exception.dart';
import '../providers/jellyseerr_providers.dart';
import '../../../../shared/widgets/settings_section.dart';

class JellyseerrConnectScreen extends ConsumerStatefulWidget {
  const JellyseerrConnectScreen({super.key});

  @override
  ConsumerState<JellyseerrConnectScreen> createState() =>
      _JellyseerrConnectScreenState();
}

class _JellyseerrConnectScreenState
    extends ConsumerState<JellyseerrConnectScreen> {
  final _urlController = TextEditingController(
    text: 'http://jellyseerr.local:5055',
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
      setState(
        () => _error = AppLocalizations.of(context).mediaErrorEnterUrlApiKey,
      );
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ref
          .read(jellyseerrConnectionProvider.notifier)
          .signIn(
            baseUrl: url.endsWith('/') ? url.substring(0, url.length - 1) : url,
            apiKey: key,
          );
      if (mounted) Navigator.of(context).pop();
    } on MediaApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(
        () => _error = AppLocalizations.of(context).mediaErrorUnreachable,
      );
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Jellyseerr')),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 16),
                LanDiscoverySection(
                  signature: ServiceSignatures.jellyseerr,
                  onSelected: (url) =>
                      setState(() => _urlController.text = url),
                ),
                SettingsSection(
                  footer: Text(
                    AppLocalizations.of(context).jellyseerrApiKeyHint,
                  ),
                  children: [
                    CupertinoTextFormFieldRow(
                      controller: _urlController,
                      prefix: Text(
                        AppLocalizations.of(context).connectUrlLabel,
                      ),
                      keyboardType: TextInputType.url,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _keyController,
                      prefix: Text(
                        AppLocalizations.of(context).mediaApiKeyLabel,
                      ),
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
                      : Text(AppLocalizations.of(context).commonConnect),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
