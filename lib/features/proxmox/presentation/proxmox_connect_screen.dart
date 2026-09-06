import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/direct_home_access.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/discovery/lan_discovery_section.dart';
import '../../../shared/discovery/service_signatures.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../data/proxmox_credentials_store.dart';
import '../providers/proxmox_providers.dart';

class ProxmoxConnectScreen extends ConsumerStatefulWidget {
  const ProxmoxConnectScreen({
    super.key,
    this.recovery = false,
    this.popOnSuccess = true,
  });
  final bool recovery;
  final bool popOnSuccess;
  @override
  ConsumerState<ProxmoxConnectScreen> createState() =>
      _ProxmoxConnectScreenState();
}

class _ProxmoxConnectScreenState
    extends MediaSessionState<ProxmoxConnectScreen> {
  final _hostController = TextEditingController();
  late final _portController = TextEditingController(
    text: widget.recovery ? '' : '8006',
  );
  late final _realmController = TextEditingController(
    text: widget.recovery ? '' : 'pam',
  );
  late final _userController = TextEditingController(
    text: widget.recovery ? '' : 'root',
  );
  final _passwordController = TextEditingController();
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  ProxmoxConnection? _connection;
  bool Function()? _operationOwner;
  bool _visible = true,
      _allowSelfSigned = false,
      _connecting = false,
      _cleared = false;
  late bool _recovery = widget.recovery;
  String? _error;
  bool _expectOwnLoading = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(proxmoxConnectionProvider, (previous, next) {
      if (!next.isLoading || previous?.isLoading == true) return;
      // signIn retires a confirmed reader synchronously before its first await.
      // Only that one transition belongs to this form; external reloads retire
      // held callbacks even when Riverpod keeps the same notifier object.
      if (_expectOwnLoading) {
        _expectOwnLoading = false;
        return;
      }
      if (mounted) {
        setState(() {
          sessionGeneration++;
          clearPendingInteraction();
        });
      }
    });
  }

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
    _hostController.clear();
    _portController.clear();
    _realmController.clear();
    _userController.clear();
    _passwordController.clear();
    _allowSelfSigned = false;
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
    _hostController.dispose();
    _portController.dispose();
    _realmController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _selectDiscovered(String baseUrl, int generation) {
    if (!_current(generation)) return;
    final uri = Uri.tryParse(baseUrl);
    if (uri == null) return;
    setState(() {
      _hostController.text = uri.host;
      if (uri.hasPort) _portController.text = uri.port.toString();
    });
  }

  Future<void> _connect(int generation, ProxmoxConnection connection) async {
    bool current() => _current(generation);
    if (!current() || _connecting) return;
    final input = _hostController.text.trim();
    final address = Uri.tryParse(
      input.contains('://') ? input : 'https://$input',
    );
    final host = address?.host ?? '';
    final port = address?.hasPort == true
        ? address!.port
        : int.tryParse(_portController.text.trim());
    final realm = _realmController.text.trim();
    final username = _userController.text.trim();
    final password = _passwordController.text;
    final allowSelfSigned = _allowSelfSigned;
    if (host.isEmpty ||
        input.contains('@') ||
        RegExp(r'[\s\\]').hasMatch(input) ||
        address?.scheme != 'https' ||
        address!.userInfo.isNotEmpty ||
        address.hasQuery ||
        address.hasFragment ||
        (address.path.isNotEmpty && address.path != '/') ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        realm.isEmpty ||
        username.isEmpty ||
        password.isEmpty) {
      setState(
        () => _error = AppLocalizations.of(context).proxmoxErrorEnterFields,
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
      final previous = ref.read(proxmoxConnectionProvider);
      if (!current()) return;
      _expectOwnLoading =
          !previous.isLoading && !previous.hasError && previous.value != null;
      final operation = connection.signIn(
        host: host,
        port: port,
        username: username,
        realm: realm,
        password: password,
        allowSelfSigned: allowSelfSigned,
        isCurrent: current,
      );
      _expectOwnLoading = false;
      await operation;
      if (mounted &&
          current() &&
          widget.popOnSuccess &&
          Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (current())
        setState(
          () => _error = AppLocalizations.of(context).mediaErrorUnreachable,
        );
    } finally {
      _expectOwnLoading = false;
      if (identical(_operationOwner, current)) _operationOwner = null;
      if (current()) setState(() => _connecting = false);
    }
  }

  Future<void> _clear(int generation, ProxmoxCredentialsStore store) async {
    bool current() => _current(generation);
    if (!current() || _connecting) return;
    setState(() {
      _connecting = true;
      _error = null;
      _cleared = false;
    });
    try {
      await store.clear(isCurrent: current);
      if (current())
        setState(() {
          _clearFields();
          _cleared = true;
        });
    } catch (_) {
      if (current())
        setState(
          () => _error = AppLocalizations.of(context).mediaErrorUnreachable,
        );
    } finally {
      if (current()) setState(() => _connecting = false);
    }
  }

  Widget _label(String text) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 96),
    child: Text(text),
  );

  @override
  Widget build(BuildContext context) {
    ref.watch(directHomeAccessProvider);
    final l10n = AppLocalizations.of(context);
    if (!_access.isCurrent)
      return CupertinoPageScaffold(
        child: Center(child: Text(l10n.mediaErrorUnreachable)),
      );
    final reading = ref.watch(proxmoxConnectionProvider);
    final error = reading.error;
    if (!_recovery &&
        error is DirectHomeAccessException &&
        {'pending_mutation', 'write_unconfirmed'}.contains(error.code)) {
      _recovery = true;
      _clearFields();
    }
    if (reading.isLoading && !_connecting)
      return const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      );
    if (reading.hasError && !_recovery)
      return CupertinoPageScaffold(
        child: Center(child: Text(l10n.mediaErrorUnreachable)),
      );
    final generation = sessionGeneration;
    final active = _current(generation);
    final connection = ref.read(proxmoxConnectionProvider.notifier);
    final store = ref.read(proxmoxCredentialsStoreProvider);
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Proxmox VE')),
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
                        : l10n.proxmoxConnectionIncomplete,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                ],
                if (active && !_recovery)
                  LanDiscoverySection(
                    signature: ServiceSignatures.proxmox,
                    onSelected: (url) => _selectDiscovered(url, generation),
                  ),
                SettingsSection(
                  children: [
                    CupertinoTextFormFieldRow(
                      controller: _hostController,
                      enabled: active && !_connecting,
                      prefix: _label(l10n.proxmoxHostLabel),
                      placeholder: 'proxmox.local',
                      keyboardType: TextInputType.url,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _portController,
                      enabled: active && !_connecting,
                      prefix: _label(l10n.proxmoxPortLabel),
                      keyboardType: TextInputType.number,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _realmController,
                      enabled: active && !_connecting,
                      prefix: _label(l10n.proxmoxRealmLabel),
                      placeholder: 'pam',
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _userController,
                      enabled: active && !_connecting,
                      prefix: _label(l10n.mediaUserLabel),
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _passwordController,
                      enabled: active && !_connecting,
                      prefix: _label(l10n.mediaPasswordLabel),
                      obscureText: true,
                    ),
                  ],
                ),
                SettingsSection(
                  footer: Text(l10n.proxmoxSelfSignedHint),
                  children: [
                    CupertinoListTile(
                      title: Text(l10n.proxmoxAllowSelfSigned),
                      trailing: CupertinoSwitch(
                        value: _allowSelfSigned,
                        onChanged: active && !_connecting
                            ? (value) {
                                if (_current(generation))
                                  setState(() => _allowSelfSigned = value);
                              }
                            : null,
                      ),
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
                      l10n.proxmoxRemoveConnection,
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
