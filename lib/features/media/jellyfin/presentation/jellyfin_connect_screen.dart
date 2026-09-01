import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../data/media_api_exception.dart';
import '../data/jellyfin_discovery.dart';
import '../providers/jellyfin_providers.dart';

class JellyfinConnectScreen extends ConsumerStatefulWidget {
  const JellyfinConnectScreen({super.key});

  @override
  ConsumerState<JellyfinConnectScreen> createState() =>
      _JellyfinConnectScreenState();
}

class _JellyfinConnectScreenState extends ConsumerState<JellyfinConnectScreen> {
  final _urlController = TextEditingController(
    text: 'http://jellyfin.local:8096',
  );
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _connecting = false;
  String? _error;

  final _discovery = JellyfinDiscoveryService();
  List<DiscoveredJellyfinServer> _discovered = [];
  bool _scanning = true;

  @override
  void initState() {
    super.initState();
    _startDiscovery();
  }

  Future<void> _startDiscovery() async {
    try {
      _discovery.servers.listen((servers) {
        if (!mounted) return;
        setState(() => _discovered = servers);
      });
      await _discovery.start();
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _scanning = false);
      });
    } catch (_) {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _selectDiscovered(DiscoveredJellyfinServer server) {
    setState(() => _urlController.text = server.baseUrl);
  }

  @override
  void dispose() {
    _discovery.stop();
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
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
          .read(jellyfinConnectionProvider.notifier)
          .signIn(
            baseUrl: url.endsWith('/') ? url.substring(0, url.length - 1) : url,
            username: username,
            password: password,
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
    final l10n = AppLocalizations.of(context);
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Jellyfin')),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 16),
                if (_discovered.isNotEmpty || _scanning) ...[
                  CupertinoListSection.insetGrouped(
                    header: Text(l10n.commonFoundOnNetwork),
                    children: [
                      for (final server in _discovered)
                        CupertinoListTile(
                          title: Text(server.name),
                          subtitle: Text(server.baseUrl),
                          trailing: const CupertinoListTileChevron(),
                          onTap: () => _selectDiscovered(server),
                        ),
                      if (_scanning && _discovered.isEmpty)
                        CupertinoListTile(
                          leading: const CupertinoActivityIndicator(),
                          title: Text(l10n.commonScanning),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                CupertinoListSection.insetGrouped(
                  children: [
                    CupertinoTextFormFieldRow(
                      controller: _urlController,
                      prefix: Text(l10n.connectUrlLabel),
                      placeholder: 'http://jellyfin.local:8096',
                      keyboardType: TextInputType.url,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _userController,
                      prefix: Text(l10n.mediaUserLabel),
                      placeholder: l10n.mediaUsernamePlaceholder,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _passwordController,
                      prefix: Text(l10n.mediaPasswordLabel),
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
                      : Text(l10n.commonConnect),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
