import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/direct_home_access.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../data/keenetic_config.dart';
import '../data/keenetic_credentials_store.dart';
import '../providers/keenetic_providers.dart';

class KeeneticConnectScreen extends ConsumerStatefulWidget {
  const KeeneticConnectScreen({
    super.key,
    this.recovery = false,
    this.popOnSuccess = true,
  });
  final bool recovery;
  final bool popOnSuccess;

  @override
  ConsumerState<KeeneticConnectScreen> createState() =>
      _KeeneticConnectScreenState();
}

class _KeeneticConnectScreenState
    extends MediaSessionState<KeeneticConnectScreen> {
  static const _defaultUrl = 'http://192.168.1.1';
  bool _gatewayRequested = false;
  bool _loaded = false;
  KeeneticConnection? _observedConnection;
  late final _urlController = TextEditingController(
    text: widget.recovery ? '' : _defaultUrl,
  );
  late final _userController = TextEditingController(
    text: widget.recovery ? '' : 'admin',
  );
  final _passwordController = TextEditingController();
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  KeeneticConnection? _connection;
  bool Function()? _operationOwner;
  bool _visible = true;
  bool _connecting = false;
  late bool _recovery = widget.recovery;
  bool _cleared = false;
  String? _error;

  bool _current(int generation) =>
      sessionCurrent(generation) &&
      _access.isCurrent &&
      identical(_access, ref.read(directHomeAccessProvider)) &&
      (_connecting || !ref.read(keeneticConnectionProvider).isLoading) &&
      identical(
        _observedConnection,
        ref.read(keeneticConnectionProvider.notifier),
      ) &&
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

  Future<void> _prefillGatewayIp(int generation) async {
    if (!_current(generation) || _recovery) return;
    try {
      final gateway = await NetworkInfo().getWifiGatewayIP();
      if (!_current(generation) ||
          _recovery ||
          gateway == null ||
          gateway.length > 45 ||
          InternetAddress.tryParse(gateway) == null ||
          _urlController.text != _defaultUrl ||
          _userController.text != 'admin' ||
          _passwordController.text.isNotEmpty) {
        return;
      }
      setState(
        () =>
            _urlController.text = Uri(scheme: 'http', host: gateway).toString(),
      );
    } catch (_) {
      // Gateway discovery never changes a confirmed or recovery credential tuple.
    }
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

  Future<void> _connect(int generation, KeeneticConnection connection) async {
    bool current() => _current(generation);
    if (!current() || _connecting) return;
    final rawUrl = _urlController.text.trim();
    final username = _userController.text.trim();
    final password = _passwordController.text;
    if (rawUrl.isEmpty || username.isEmpty) {
      setState(
        () =>
            _error = AppLocalizations.of(context).keeneticErrorEnterUrlUsername,
      );
      return;
    }
    final String url;
    try {
      url = KeeneticConfig.normalizeBaseUrl(rawUrl);
    } on FormatException {
      setState(() => _error = AppLocalizations.of(context).keeneticInvalidUrl);
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
          () => _error = AppLocalizations.of(context).keeneticErrorUnreachable,
        );
      }
    } finally {
      if (identical(_operationOwner, current)) _operationOwner = null;
      if (current()) setState(() => _connecting = false);
    }
  }

  Future<void> _clear(int generation, KeeneticCredentialsStore store) async {
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
          () => _error = AppLocalizations.of(context).keeneticErrorUnreachable,
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
    if (!_access.isCurrent ||
        !identical(_access, ref.read(directHomeAccessProvider))) {
      clearPendingInteraction();
      return CupertinoPageScaffold(
        child: Center(child: Text(l10n.keeneticErrorUnreachable)),
      );
    }
    // A standalone form also owns the provider subscription during verification.
    final reading = ref.watch(keeneticConnectionProvider);
    ref.listen(keeneticConnectionProvider, (previous, next) {
      final owner = _operationOwner;
      final ownLoading =
          next.isLoading &&
          _connecting &&
          owner != null &&
          (_connection?.publishesLoadingFor(owner) ?? false);
      final retiredVerification =
          _connecting &&
          owner != null &&
          !(_connection?.ownsVerification(owner) ?? false);
      if (!ownLoading &&
          _loaded &&
          previous != null &&
          (retiredVerification ||
              next.isLoading ||
              !_connecting && !identical(previous, next))) {
        setState(() {
          sessionGeneration++;
          clearPendingInteraction();
        });
      }
    });
    final observed = ref.read(keeneticConnectionProvider.notifier);
    if (_observedConnection != null &&
        !identical(observed, _observedConnection)) {
      sessionGeneration++;
      clearPendingInteraction();
    }
    _observedConnection = observed;
    final error = reading.error;
    if (!_recovery && error is DirectHomeAccessException) {
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
        child: Center(child: Text(l10n.keeneticErrorUnreachable)),
      );
    }
    _loaded = true;
    final generation = sessionGeneration;
    final active = _current(generation);
    if (active && !_recovery && !_gatewayRequested) {
      _gatewayRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_prefillGatewayIp(generation));
      });
    }
    final connection = ref.read(keeneticConnectionProvider.notifier);
    final store = ref.read(keeneticCredentialsStoreProvider);
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Keenetic')),
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
                        : l10n.keeneticConnectionIncomplete,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                ],
                CupertinoListSection.insetGrouped(
                  footer: Text(l10n.keeneticCredentialsHint),
                  children: [
                    CupertinoTextFormFieldRow(
                      controller: _urlController,
                      enabled: active && !_connecting,
                      prefix: _fieldLabel(l10n.connectUrlLabel),
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _userController,
                      enabled: active && !_connecting,
                      prefix: _fieldLabel(l10n.mediaUserLabel),
                      autocorrect: false,
                      enableSuggestions: false,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _passwordController,
                      enabled: active && !_connecting,
                      prefix: _fieldLabel(l10n.mediaPasswordLabel),
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _connect(generation, connection),
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
                      l10n.keeneticRemoveConnection,
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
