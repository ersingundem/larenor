import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/direct_home_access.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/discovery/lan_discovery_section.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../../hub/presentation/media_session_state.dart';
import '../data/qbittorrent_credentials_store.dart';
import '../providers/qbittorrent_providers.dart';

class QbittorrentConnectScreen extends ConsumerStatefulWidget {
  const QbittorrentConnectScreen({
    super.key,
    this.recovery = false,
    this.popOnSuccess = true,
  });
  final bool recovery;
  final bool popOnSuccess;

  @override
  ConsumerState<QbittorrentConnectScreen> createState() =>
      _QbittorrentConnectScreenState();
}

class _QbittorrentConnectScreenState
    extends MediaSessionState<QbittorrentConnectScreen> {
  late final _urlController = TextEditingController(
    text: widget.recovery ? '' : 'http://qbittorrent.local:8080',
  );
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  QbittorrentConnection? _connection;
  bool Function()? _operationOwner;
  bool _visible = true;
  bool _connecting = false;
  late bool _recovery = widget.recovery;
  bool _cleared = false;
  String? _error;

  bool _current(int generation) =>
      sessionCurrent(generation) &&
      _access.isCurrent &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (_visible && !visible) {
      sessionGeneration++;
      clearPendingInteraction();
    }
    _visible = visible;
  }

  void _clearFields() {
    _urlController.clear();
    _userController.clear();
    _passwordController.clear();
  }

  @override
  void clearPendingInteraction() {
    final owner = _operationOwner;
    if (owner != null) _connection?.cancelSignIn(owner);
    _operationOwner = null;
    _clearFields();
    _connecting = false;
    _error = null;
    _cleared = false;
  }

  @override
  void dispose() {
    clearPendingInteraction();
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _connect(
    int generation,
    QbittorrentConnection connection,
  ) async {
    bool current() => _current(generation);
    if (!current() || _connecting) return;
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
      _cleared = false;
    });
    _connection = connection;
    _operationOwner = current;
    try {
      await connection.signIn(
        baseUrl: url.endsWith('/') ? url.substring(0, url.length - 1) : url,
        username: username,
        password: password,
        isCurrent: current,
      );
      if (mounted &&
          current() &&
          widget.popOnSuccess &&
          Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (current()) {
        setState(
          () => _error = AppLocalizations.of(context).mediaErrorUnreachable,
        );
      }
    } finally {
      if (identical(_operationOwner, current)) _operationOwner = null;
      if (current()) setState(() => _connecting = false);
    }
  }

  Future<void> _clear(int generation, QbittorrentCredentialsStore store) async {
    bool current() => _current(generation);
    if (!current() || _connecting) return;
    setState(() {
      _connecting = true;
      _error = null;
      _cleared = false;
    });
    try {
      await store.clear(isCurrent: current);
      if (current()) {
        setState(() {
          _clearFields();
          _cleared = true;
        });
      }
    } catch (_) {
      if (current()) {
        setState(
          () => _error = AppLocalizations.of(context).mediaErrorUnreachable,
        );
      }
    } finally {
      if (current()) setState(() => _connecting = false);
    }
  }

  Widget _fieldLabel(String label) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 96),
    child: Text(label),
  );

  @override
  Widget build(BuildContext context) {
    ref.watch(directHomeAccessProvider);
    final l10n = AppLocalizations.of(context);
    if (!_access.isCurrent) {
      return CupertinoPageScaffold(
        child: Center(child: Text(l10n.mediaErrorUnreachable)),
      );
    }
    // A standalone form also owns the provider subscription during verification.
    final reading = ref.watch(qbittorrentConnectionProvider);
    final error = reading.error;
    if (!_recovery &&
        error is DirectHomeAccessException &&
        {'pending_mutation', 'write_unconfirmed'}.contains(error.code)) {
      _recovery = true;
      _clearFields();
    }
    if (reading.isLoading && !_connecting) {
      return const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    if (reading.hasError && !_recovery) {
      return CupertinoPageScaffold(
        child: Center(child: Text(l10n.mediaErrorUnreachable)),
      );
    }
    final generation = sessionGeneration;
    final active = _current(generation);
    final connection = ref.read(qbittorrentConnectionProvider.notifier);
    final store = ref.read(qbittorrentCredentialsStoreProvider);
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
                if (_recovery) ...[
                  Text(
                    _cleared
                        ? l10n.commonDone
                        : l10n.qbittorrentConnectionIncomplete,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                ],
                if (active && !_recovery)
                  LanDiscoverySection(
                    signature: ServiceSignatures.qbittorrent,
                    onSelected: (url) {
                      if (_current(generation)) {
                        setState(() => _urlController.text = url);
                      }
                    },
                  ),
                CupertinoListSection.insetGrouped(
                  children: [
                    CupertinoTextFormFieldRow(
                      controller: _urlController,
                      enabled: active && !_connecting,
                      prefix: _fieldLabel(l10n.connectUrlLabel),
                      keyboardType: TextInputType.url,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _userController,
                      enabled: active && !_connecting,
                      prefix: _fieldLabel(l10n.mediaUserLabel),
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _passwordController,
                      enabled: active && !_connecting,
                      prefix: _fieldLabel(l10n.mediaPasswordLabel),
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
                  onPressed: _connecting || !active
                      ? null
                      : () => _connect(generation, connection),
                  child: _connecting
                      ? const CupertinoActivityIndicator(
                          color: CupertinoColors.white,
                        )
                      : Text(l10n.commonConnect),
                ),
                if (_recovery) ...[
                  const SizedBox(height: 12),
                  CupertinoButton(
                    onPressed: _connecting || !active
                        ? null
                        : () => _clear(generation, store),
                    child: Text(
                      l10n.qbittorrentRemoveConnection,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
