import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/direct_home_access.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../hub/presentation/media_session_state.dart';
import '../data/jellyfin_discovery.dart';
import '../providers/jellyfin_providers.dart';

// Internal dependency seam; production uses Jellyfin's existing UDP discovery.
final jellyfinDiscoveryFactoryProvider = Provider<JellyfinDiscoveryService Function()>(
  (ref) => JellyfinDiscoveryService.new,
);

class JellyfinConnectScreen extends ConsumerStatefulWidget {
  const JellyfinConnectScreen({super.key});
  @override ConsumerState<JellyfinConnectScreen> createState() => _JellyfinConnectScreenState();
}

class _JellyfinConnectScreenState extends MediaSessionState<JellyfinConnectScreen> {
  final _urlController = TextEditingController();
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  JellyfinConnection? _connection;
  bool _initialized = false, _pendingRecovery = false, _visible = true;
  bool _connecting = false, _cleared = false, _scanning = false, _discoveryAttempted = false;
  String? _error;
  JellyfinDiscoveryService? _discovery;
  StreamSubscription<List<DiscoveredJellyfinServer>>? _discoverySubscription;
  Timer? _discoveryTimer;
  List<DiscoveredJellyfinServer> _discovered = [];

  bool _current(int generation) => sessionCurrent(generation) && _access.isCurrent &&
    TickerMode.valuesOf(context).enabled && (ModalRoute.of(context)?.isCurrent ?? true) &&
    _connection != null && identical(_connection, ref.read(jellyfinConnectionProvider.notifier));

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled && (ModalRoute.of(context)?.isCurrent ?? true);
    if (_visible && !visible) { sessionGeneration++; clearPendingInteraction(); }
    _visible = visible;
  }

  void _stopDiscovery() {
    _discoveryTimer?.cancel(); _discoveryTimer = null;
    final subscription = _discoverySubscription; _discoverySubscription = null;
    final discovery = _discovery; _discovery = null;
    if (subscription != null) unawaited(subscription.cancel());
    if (discovery != null) unawaited(discovery.stop().catchError((_) {}));
    _scanning = false; _discovered = [];
  }

  @override void clearPendingInteraction() {
    _urlController.clear(); _userController.clear(); _passwordController.clear();
    _connecting = false; _error = null; _cleared = false;
    _stopDiscovery();
  }

  Future<void> _startDiscovery(int generation) async {
    if (!_current(generation) || _pendingRecovery || _discoveryAttempted) return;
    _discoveryAttempted = true;
    final discovery = ref.read(jellyfinDiscoveryFactoryProvider)();
    _discovery = discovery;
    bool current() => _current(generation) && identical(discovery, _discovery);
    setState(() => _scanning = true);
    try {
      _discoverySubscription = discovery.servers.listen((servers) {
        if (current()) setState(() => _discovered = servers);
      });
      await discovery.start(isCurrent: current);
      if (!current()) { _stopDiscovery(); return; }
      _discoveryTimer = Timer(const Duration(seconds: 4), () {
        if (current()) setState(() => _scanning = false);
      });
    } catch (_) {
      _stopDiscovery();
      if (_current(generation)) setState(() {});
    }
  }

  @override void dispose() {
    _stopDiscovery();
    _urlController.dispose(); _userController.dispose(); _passwordController.dispose();
    super.dispose();
  }

  Future<void> _connect(int generation) async {
    if (!_current(generation) || _connecting) return;
    final connection = _connection!;
    final url = _urlController.text.trim(), username = _userController.text.trim();
    final password = _passwordController.text;
    if (url.isEmpty || username.isEmpty) {
      setState(() => _error = AppLocalizations.of(context).mediaErrorEnterUrlUsername);
      return;
    }
    setState(() { _connecting = true; _error = null; });
    bool current() => _current(generation) && identical(connection, _connection);
    try {
      await connection.signIn(baseUrl: url, username: username, password: password, isCurrent: current);
      if (current()) Navigator.of(context).maybePop();
    } catch (_) {
      if (current()) setState(() => _error = AppLocalizations.of(context).mediaErrorUnreachable);
    } finally {
      if (current()) setState(() => _connecting = false);
    }
  }

  Future<void> _clear(int generation) async {
    if (!_current(generation) || _connecting || !_pendingRecovery) return;
    final store = ref.read(jellyfinCredentialsStoreProvider);
    bool current() => _current(generation);
    setState(() { _connecting = true; _error = null; _cleared = false; });
    try {
      await store.clear(isCurrent: current);
      if (current()) setState(() {
        _urlController.clear(); _userController.clear(); _passwordController.clear(); _cleared = true;
      });
    } catch (_) {
      if (current()) setState(() => _error = AppLocalizations.of(context).mediaErrorUnreachable);
    } finally {
      if (current()) setState(() => _connecting = false);
    }
  }

  @override Widget build(BuildContext context) {
    ref.watch(directHomeAccessProvider);
    final state = ref.watch(jellyfinConnectionProvider);
    final l10n = AppLocalizations.of(context);
    final pending = state.error is DirectHomeAccessException &&
      (state.error as DirectHomeAccessException).code == 'pending_mutation';
    if (!_access.isCurrent || state.hasError && !pending) {
      _stopDiscovery();
      return CupertinoPageScaffold(child: Center(child: Text(l10n.mediaErrorUnreachable)));
    }
    if (state.isLoading) return const CupertinoPageScaffold(child: Center(child: CupertinoActivityIndicator()));
    if (!_initialized) {
      _initialized = true; _pendingRecovery = pending;
      _connection = ref.read(jellyfinConnectionProvider.notifier);
      if (!pending) _urlController.text = 'http://jellyfin.local:8096';
    }
    final generation = sessionGeneration;
    final active = _current(generation);
    if (active && !_pendingRecovery && !_discoveryAttempted) {
      WidgetsBinding.instance.addPostFrameCallback((_) { _startDiscovery(generation); });
    }
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Jellyfin')),
      child: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
        child: ListView(padding: const EdgeInsets.all(24), children: [
          const SizedBox(height: 16),
          if (_discovered.isNotEmpty || _scanning) ...[
            SettingsSection(header: Text(l10n.commonFoundOnNetwork), children: [
              for (final server in _discovered) CupertinoListTile(title: Text(server.name), subtitle: Text(server.baseUrl),
                trailing: const CupertinoListTileChevron(), onTap: active ? () {
                  if (_current(generation)) setState(() => _urlController.text = server.baseUrl);
                } : null),
              if (_scanning && _discovered.isEmpty) CupertinoListTile(leading: const CupertinoActivityIndicator(), title: Text(l10n.commonScanning)),
            ]), const SizedBox(height: 8),
          ],
          SettingsSection(children: [
            CupertinoTextFormFieldRow(controller: _urlController, prefix: Text(l10n.connectUrlLabel),
              placeholder: _pendingRecovery ? '' : 'http://jellyfin.local:8096', keyboardType: TextInputType.url, enabled: active && !_connecting),
            CupertinoTextFormFieldRow(controller: _userController, prefix: Text(l10n.mediaUserLabel),
              placeholder: l10n.mediaUsernamePlaceholder, enabled: active && !_connecting),
            CupertinoTextFormFieldRow(controller: _passwordController, prefix: Text(l10n.mediaPasswordLabel),
              obscureText: true, enabled: active && !_connecting),
          ]),
          if (_error != null) ...[const SizedBox(height: 12), Text(_error!, textAlign: TextAlign.center,
            style: TextStyle(color: CupertinoColors.systemRed.resolveFrom(context)))],
          if (_cleared) ...[const SizedBox(height: 12), Text(l10n.commonDone, textAlign: TextAlign.center)],
          const SizedBox(height: 20),
          CupertinoButton.filled(onPressed: active && !_connecting ? () => _connect(generation) : null,
            child: _connecting ? const CupertinoActivityIndicator(color: CupertinoColors.white) : Text(l10n.commonConnect)),
          if (_pendingRecovery) CupertinoButton(onPressed: active && !_connecting ? () => _clear(generation) : null,
            child: Text(l10n.arrRemoveConnection)),
        ]),
      ))),
    );
  }
}
