import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../../ha_client/data/ha_api_exception.dart';
import '../../ha_client/data/rest_client.dart';
import '../data/ha_connection_config.dart';
import '../data/ha_discovery.dart';
import '../providers/auth_providers.dart';

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _urlController = TextEditingController(
    text: 'http://homeassistant.local:8123',
  );
  final _tokenController = TextEditingController();
  final _tokenFocusNode = FocusNode();

  final _discovery = HaDiscoveryService();
  List<DiscoveredHaServer> _discovered = [];
  bool _scanning = true;

  bool _isConnecting = false;
  String? _errorMessage;

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
      Future.delayed(const Duration(seconds: 6), () {
        if (mounted) setState(() => _scanning = false);
      });
    } catch (_) {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  void dispose() {
    _discovery.stop();
    _urlController.dispose();
    _tokenController.dispose();
    _tokenFocusNode.dispose();
    super.dispose();
  }

  void _selectDiscovered(DiscoveredHaServer server) {
    setState(() => _urlController.text = server.baseUrl);
    _tokenFocusNode.requestFocus();
  }

  Future<void> _connect() async {
    final urlInput = _urlController.text.trim();
    final tokenInput = _tokenController.text.trim();
    if (urlInput.isEmpty || tokenInput.isEmpty) {
      setState(
        () =>
            _errorMessage = AppLocalizations.of(context).connectErrorEnterBoth,
      );
      return;
    }

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    final config = HaConnectionConfig(
      baseUrl: HaConnectionConfig.normalizeBaseUrl(urlInput),
      token: tokenInput,
    );

    final client = HaRestClient(baseUrl: config.baseUrl, token: config.token);
    try {
      await client.checkConnection();
      await ref.read(connectionConfigProvider.notifier).signIn(config);
    } on HaApiException catch (e) {
      setState(() => _errorMessage = e.message);
    } catch (_) {
      setState(
        () =>
            _errorMessage = AppLocalizations.of(context)
                .connectErrorUnreachable,
      );
    } finally {
      client.dispose();
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.connectScreenTitle),
          ),
          SliverSafeArea(
            top: false,
            sliver: SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l10n.connectScreenIntro,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (_discovered.isNotEmpty || _scanning) ...[
                          _buildDiscoverySection(context),
                          const SizedBox(height: 8),
                        ],
                        CupertinoListSection.insetGrouped(
                          header: Text(l10n.connectServerHeader),
                          children: [
                            CupertinoTextFormFieldRow(
                              controller: _urlController,
                              prefix: Text(l10n.connectUrlLabel),
                              placeholder: 'http://homeassistant.local:8123',
                              keyboardType: TextInputType.url,
                            ),
                            CupertinoTextFormFieldRow(
                              controller: _tokenController,
                              focusNode: _tokenFocusNode,
                              prefix: Text(l10n.connectTokenLabel),
                              placeholder: l10n.connectTokenPlaceholder,
                              obscureText: true,
                            ),
                          ],
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _errorMessage!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: CupertinoColors.systemRed.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        CupertinoButton.filled(
                          onPressed: _isConnecting ? null : _connect,
                          child: _isConnecting
                              ? const CupertinoActivityIndicator(
                                  color: CupertinoColors.white,
                                )
                              : Text(l10n.commonConnect),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.connectTokenHint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiscoverySection(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CupertinoListSection.insetGrouped(
      header: Text(l10n.commonFoundOnNetwork),
      children: [
        for (final server in _discovered)
          CupertinoListTile(
            leading: const IconBadge(
              icon: CupertinoIcons.house_fill,
              color: CupertinoColors.systemBlue,
            ),
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
    );
  }
}
