import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../../../shared/widgets/larenor_brand.dart';
import '../../ha_client/data/ha_api_exception.dart';
import '../../ha_client/data/rest_client.dart';
import '../data/ha_connection_config.dart';
import '../data/ha_discovery.dart';
import '../providers/auth_providers.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../backup/presentation/backup_screen.dart';
import '../../settings/providers/settings_providers.dart';
import '../../settings/presentation/settings_gate_screen.dart';
import '../../server/presentation/server_connection_screen.dart';
import '../../../core/app_interaction_scope.dart';

final haDiscoveryFactoryProvider = Provider<HaDiscoveryService Function()>(
  (ref) => HaDiscoveryService.new,
);

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key, this.initialUrl});

  /// Pre-fills the URL field — used when re-opening this screen from
  /// Settings to refresh a stale connection, so the user only has to
  /// paste a new token, not retype the server address too.
  final String? initialUrl;

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen>
    with WidgetsBindingObserver {
  late final _urlController = TextEditingController(
    text: widget.initialUrl ?? 'http://homeassistant.local:8123',
  );
  final _tokenController = TextEditingController();
  final _tokenFocusNode = FocusNode();

  late final HaDiscoveryService _discovery;
  List<DiscoveredHaServer> _discovered = [];
  bool _scanning = true;

  bool _isConnecting = false;
  bool _openingBackup = false;
  int _serverNavigationEpoch = 0;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _discovery = ref.read(haDiscoveryFactoryProvider)();
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
    WidgetsBinding.instance.removeObserver(this);
    _discovery.stop();
    _urlController.dispose();
    _tokenController.dispose();
    _tokenFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _serverNavigationEpoch++;
    if (mounted) setState(() {});
  }

  void _selectDiscovered(DiscoveredHaServer server) {
    setState(() => _urlController.text = server.baseUrl);
    _tokenFocusNode.requestFocus();
  }

  Future<void> _restoreBackup() async {
    if (_isConnecting || _openingBackup) return;
    setState(() => _openingBackup = true);
    try {
      final pin = await ref.read(pinLockStoreProvider).read();
      if (!mounted) return;
      if (pin != null || ref.read(connectionConfigProvider).value != null) {
        return;
      }
      await Navigator.of(context).push<void>(
        CupertinoPageRoute(
          builder: (_) => const BackupScreen(freshInstall: true),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _errorMessage = AppLocalizations.of(context)
                  .settingsGateStorageError,
        );
      }
    } finally {
      if (mounted) setState(() => _openingBackup = false);
    }
  }

  Future<void> _openServer() async {
    if (_isConnecting || _openingBackup) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    final epoch = _serverNavigationEpoch;
    final interaction = AppInteractionScope.maybeRead(context);
    final interactionEpoch = interaction?.epoch;
    if (interaction?.active == false) return;
    setState(() => _openingBackup = true);
    try {
      final pin = await ref.read(pinLockStoreProvider).read();
      if (!mounted ||
          epoch != _serverNavigationEpoch ||
          interaction?.active == false ||
          interaction?.epoch != interactionEpoch ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      await Navigator.of(context).push<void>(
        CupertinoPageRoute(
          builder: (_) => pin == null
              ? const ServerConnectionScreen(freshInstall: true)
              : const SettingsGateScreen(),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _errorMessage = AppLocalizations.of(context)
                  .settingsGateStorageError,
        );
      }
    } finally {
      if (mounted) setState(() => _openingBackup = false);
    }
  }

  Future<void> _connect() async {
    if (_isConnecting || _openingBackup) return;
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

    HaRestClient? client;
    try {
      final config = HaConnectionConfig(
        baseUrl: HaConnectionConfig.normalizeBaseUrl(urlInput),
        token: tokenInput,
      );
      client = HaRestClient(baseUrl: config.baseUrl, token: config.token);
      await client.checkConnection();
      if (!mounted) return;
      await ref.read(connectionConfigProvider.notifier).signIn(config);
    } on HaApiException catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(
        () => _errorMessage = switch (e.statusCode) {
          401 => l10n.connectErrorAuthentication,
          403 => l10n.connectErrorPermission,
          _ =>
            e.code == 'invalid_response'
                ? l10n.connectErrorNotHomeAssistant
                : l10n.connectErrorUnreachable,
        },
      );
    } on FormatException {
      if (mounted) {
        setState(
          () => _errorMessage = AppLocalizations.of(context).connectErrorUrl,
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(
        () =>
            _errorMessage = AppLocalizations.of(context)
                .connectErrorUnreachable,
      );
    } finally {
      client?.dispose();
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final serverEpoch = _serverNavigationEpoch;
    final pin = ref.watch(pinLockProvider);
    final connection = ref.watch(connectionConfigProvider);
    final canRestore =
        widget.initialUrl == null &&
        pin.hasValue &&
        pin.value == null &&
        connection.hasValue &&
        connection.value == null;
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
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: LarenorBrand(centered: true),
                        ),
                        const SizedBox(height: 8),
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
                        SettingsSection(
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
                          onPressed: _isConnecting || _openingBackup
                              ? null
                              : _connect,
                          child: _isConnecting
                              ? const CupertinoActivityIndicator(
                                  color: CupertinoColors.white,
                                )
                              : Text(l10n.commonConnect),
                        ),
                        if (canRestore) ...[
                          const SizedBox(height: 12),
                          CupertinoButton(
                            key: const ValueKey('connect-restore-backup'),
                            onPressed: _isConnecting || _openingBackup
                                ? null
                                : _restoreBackup,
                            child: Text(
                              l10n.backupConnectRestore,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        CupertinoButton(
                          key: const ValueKey('connect-larenor-server'),
                          onPressed: _isConnecting || _openingBackup
                              ? null
                              : () {
                                  if (serverEpoch == _serverNavigationEpoch) {
                                    _openServer();
                                  }
                                },
                          child: Text(
                            l10n.serverConnectEntry,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.connectTokenHint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: AppText.hint.fontSize,
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
    return SettingsSection(
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
