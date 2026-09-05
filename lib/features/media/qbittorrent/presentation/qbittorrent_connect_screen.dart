import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/discovery/lan_discovery_section.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../../data/media_api_exception.dart';
import '../providers/qbittorrent_providers.dart';

class QbittorrentConnectScreen extends ConsumerStatefulWidget {
  const QbittorrentConnectScreen({super.key});

  @override
  ConsumerState<QbittorrentConnectScreen> createState() =>
      _QbittorrentConnectScreenState();
}

class _QbittorrentConnectScreenState
    extends ConsumerState<QbittorrentConnectScreen> {
  final _urlController = TextEditingController(
    text: 'http://qbittorrent.local:8080',
  );
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _connecting = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!mounted || _connecting) return;
    final url = _urlController.text.trim();
    final username = _userController.text.trim();
    final password = _passwordController.text;
    if (url.isEmpty || username.isEmpty) {
      setState(
        () => _error = AppLocalizations.of(context).mediaErrorEnterUrlUsername,
      );
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ref
          .read(qbittorrentConnectionProvider.notifier)
          .signIn(
            baseUrl: url.endsWith('/') ? url.substring(0, url.length - 1) : url,
            username: username,
            password: password,
          );
      if (mounted) Navigator.of(context).pop();
    } on MediaApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(context).mediaErrorUnreachable,
        );
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('qBittorrent')),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 16),
                LanDiscoverySection(
                  signature: ServiceSignatures.qbittorrent,
                  onSelected: (url) =>
                      setState(() => _urlController.text = url),
                ),
                CupertinoListSection.insetGrouped(
                  children: [
                    CupertinoTextFormFieldRow(
                      controller: _urlController,
                      prefix: Text(
                        AppLocalizations.of(context).connectUrlLabel,
                      ),
                      keyboardType: TextInputType.url,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _userController,
                      prefix: Text(AppLocalizations.of(context).mediaUserLabel),
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _passwordController,
                      prefix: Text(
                        AppLocalizations.of(context).mediaPasswordLabel,
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
