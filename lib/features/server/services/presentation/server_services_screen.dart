import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_services_controller.dart';
import '../domain/server_service_models.dart';

/// Reached through the Settings PIN gate and a signed-in administrator account.
class ServerServicesScreen extends ConsumerStatefulWidget {
  const ServerServicesScreen({super.key});
  @override
  ConsumerState<ServerServicesScreen> createState() =>
      _ServerServicesScreenState();
}

class _ServerServicesScreenState
    extends MediaSessionState<ServerServicesScreen> {
  late final ServerAccountController _account;
  late final ServerServicesController _services;
  late final int _accountEpoch;
  ValueListenable<TickerModeData>? _ticker;
  Route<Object?>? _dialog;
  VoidCallback? _clearDraft;
  bool _visible = true, _expired = false, _loaded = false, _pinReady = false;
  bool _wasCurrent = true;

  bool get _active =>
      !_expired &&
      _visible &&
      _pinReady &&
      sessionCurrent(sessionGeneration) &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      (ModalRoute.of(context)?.isCurrent == true || _dialog?.isCurrent == true);
  bool get _enabled =>
      _active &&
      !_services.busy &&
      !_services.needsRefresh &&
      _services.failure == null;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _services = ServerServicesController(_account);
    _account.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountEpoch) ||
        _account.working ||
        _account.session?.user.canAdminister != true) {
      _expire();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = ticker;
      _visible = ticker.value.enabled;
      ticker.addListener(_visibilityChanged);
    }
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_wasCurrent && !current && _dialog == null) _expire();
    _wasCurrent = current;
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  @override
  void clearPendingInteraction() => _expire();

  void _expire() {
    if (!mounted) return;
    final wasBusy = _services.busy;
    _expired = true;
    sessionGeneration++;
    final clear = _clearDraft;
    _clearDraft = null;
    final route = _dialog;
    _dialog = null;
    void retire() {
      if (!mounted) return;
      if (route?.isActive == true) {
        clear?.call();
        route!.navigator?.removeRoute(route);
      }
      _services.invalidate();
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => retire());
    } else {
      retire();
    }
    // Expire a token rotation awaited by this screen, without cancelling a
    // different page's account form or issuing a remote logout.
    if (wasBusy && !_account.working) unawaited(_account.cancelPending());
  }

  @override
  void dispose() {
    _clearDraft = null;
    _account.removeListener(_accountChanged);
    _ticker?.removeListener(_visibilityChanged);
    _services.dispose();
    super.dispose();
  }

  bool Function() _capture() {
    final epoch = sessionGeneration;
    return () => mounted && sessionCurrent(epoch) && _active;
  }

  VoidCallback _callback(VoidCallback action) {
    final current = _capture();
    return () {
      if (current()) action();
    };
  }

  Future<void> _load() async {
    if (!_active || _services.busy || _dialog != null) return;
    await _services.load(current: _capture());
  }

  Future<T?> _show<T>(
    Widget Function(BuildContext, bool Function()) builder,
  ) async {
    if (!_enabled || _dialog != null) return null;
    final current = _capture();
    late final CupertinoDialogRoute<T> route;
    route = CupertinoDialogRoute<T>(
      context: context,
      builder: (context) {
        if (ModalRoute.isCurrentOf(context) != true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && identical(_dialog, route) && !route.isCurrent) {
              _expire();
            }
          });
        }
        return builder(
          context,
          () => current() && identical(_dialog, route) && route.isCurrent,
        );
      },
    );
    _dialog = route;
    final result = await Navigator.of(context).push(route);
    if (identical(_dialog, route)) _dialog = null;
    _clearDraft = null;
    return current() ? result : null;
  }

  Future<void> _edit([ServerService? service]) async {
    final current = _capture();
    final draft = await _show<_ServiceDraft>(
      (context, valid) => _ServiceForm(
        service: service,
        current: valid,
        registerClear: (clear) => _clearDraft = clear,
      ),
    );
    if (draft == null || !current()) return;
    await _services.save(
      previous: service,
      name: draft.name,
      kind: draft.kind,
      baseUrl: draft.baseUrl,
      credentials: draft.credentials,
      current: current,
    );
  }

  Future<void> _forget(ServerService service) async {
    final current = _capture();
    var submitted = false;
    final confirmed = await _show<bool>((context, valid) {
      final l10n = AppLocalizations.of(context);
      return CupertinoAlertDialog(
        title: Text(l10n.serverServicesForgetTitle),
        content: Text(l10n.serverServicesForgetHint),
        actions: [
          CupertinoDialogAction(
            onPressed: () {
              if (valid() && !submitted) Navigator.pop(context, false);
            },
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('service-confirm-forget'),
            isDestructiveAction: true,
            onPressed: () {
              if (!valid() || submitted) return;
              submitted = true;
              Navigator.pop(context, true);
            },
            child: Text(l10n.serverServicesForget),
          ),
        ],
      );
    });
    if (confirmed != true || !current()) return;
    await _services.forget(service, current: current);
  }

  String _failure(AppLocalizations l10n) => switch (_services.failure) {
    'service_limit_reached' => l10n.serverServicesLimit,
    'service_credentials_required' ||
    'service_endpoint_credentials' => l10n.serverServicesEndpointCredentials,
    'revision_conflict' || 'conflict' => l10n.serverServicesConflict,
    'unauthorized' => l10n.serverFailureAuthentication,
    'forbidden' || 'password_change_required' => l10n.serverFailurePermission,
    'invalid_request' => l10n.serverIncomplete,
    'rate_limited' => l10n.serverFailureRateLimit,
    _ =>
      _services.needsRefresh
          ? l10n.serverServicesUncertain
          : l10n.serverFailureConnection,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider);
    _pinReady = !pin.isLoading && !pin.hasError;
    ref.listen(pinLockProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          (previous?.hasValue == true && previous?.value != next.value)) {
        _expire();
      }
    });
    if (_active && !_loaded) {
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active) unawaited(_load());
      });
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          l10n.serverServicesTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _services,
          builder: (context, _) {
            if (!_active) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _account.session?.user.canAdminister == true
                        ? l10n.serverOpenFromSettings
                        : l10n.serverFailurePermission,
                  ),
                ),
              );
            }
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(l10n.serverServicesIntro),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Wrap(
                        children: [
                          CupertinoButton(
                            key: const ValueKey('services-add'),
                            onPressed: _enabled ? _callback(_edit) : null,
                            child: Text(l10n.serverServicesAdd),
                          ),
                          CupertinoButton(
                            key: const ValueKey('services-refresh'),
                            onPressed: _active && !_services.busy
                                ? _callback(_load)
                                : null,
                            child: Text(l10n.commonRefresh),
                          ),
                        ],
                      ),
                    ),
                    if (_services.busy)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: CupertinoActivityIndicator(),
                      ),
                    if (_services.failure != null)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(_failure(l10n)),
                        ),
                      ),
                    if (_services.services.isEmpty &&
                        !_services.busy &&
                        _services.failure == null)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(l10n.serverServicesEmpty),
                      ),
                    for (final service in _services.services)
                      _card(l10n, service),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _card(AppLocalizations l10n, ServerService service) => SettingsSection(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(service.name, style: AppText.headline),
            Text(service.kind.label, style: AppText.subhead),
            const SizedBox(height: 8),
            Text(service.baseUrl),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(switch (service.verification.state) {
                ServerServiceVerificationState.never =>
                  l10n.serverServicesNever,
                ServerServiceVerificationState.reachable =>
                  l10n.serverServicesReachable,
                ServerServiceVerificationState.authenticated =>
                  l10n.serverServicesAuthenticated,
                ServerServiceVerificationState.unavailable =>
                  l10n.serverServicesUnavailable,
                ServerServiceVerificationState.unauthorized =>
                  l10n.serverServicesUnauthorized,
                ServerServiceVerificationState.unsupported =>
                  l10n.serverServicesUnsupported,
              }, style: AppText.subhead),
            ),
            if (service.verification.checkedAt case final DateTime date)
              Text(
                '${l10n.serverServicesCheckedAt}: ${DateFormat.yMd(l10n.localeName).add_Hm().format(date.toLocal())}',
                style: AppText.footnote,
              ),
            if (service.verification.version case final String version)
              Text(version, style: AppText.footnote),
            const SizedBox(height: 8),
            Text(
              service.credentialKeys.isEmpty
                  ? l10n.serverServicesNoCredentials
                  : '${l10n.serverServicesSavedCredentials}: ${service.credentialKeys.map((key) => _credentialLabel(l10n, key)).join(', ')}',
              style: AppText.footnote,
            ),
            Wrap(
              children: [
                CupertinoButton(
                  key: ValueKey('service-check-${service.id}'),
                  onPressed: _enabled
                      ? _callback(
                          () => _services.check(service, current: _capture()),
                        )
                      : null,
                  child: Text(l10n.serverServicesCheck),
                ),
                CupertinoButton(
                  key: ValueKey('service-edit-${service.id}'),
                  onPressed: _enabled ? _callback(() => _edit(service)) : null,
                  child: Text(l10n.commonEdit),
                ),
                CupertinoButton(
                  key: ValueKey('service-forget-${service.id}'),
                  onPressed: _enabled
                      ? _callback(() => _forget(service))
                      : null,
                  child: Text(l10n.serverServicesForget),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}

String _credentialLabel(AppLocalizations l10n, String key) => switch (key) {
  'token' => l10n.serverServicesToken,
  'apiKey' => l10n.serverServicesApiKey,
  'username' => l10n.serverUsername,
  'password' => l10n.serverPassword,
  _ => l10n.serverServicesUserId,
};

String _credentialGuide(AppLocalizations l10n, ServerServiceKind kind) =>
    switch (kind) {
      ServerServiceKind.homeAssistant =>
        l10n.serverServicesHomeAssistantCredentials,
      ServerServiceKind.musicAssistant =>
        l10n.serverServicesMusicAssistantCredentials,
      ServerServiceKind.jellyfin => l10n.serverServicesJellyfinCredentials,
      ServerServiceKind.immich => l10n.serverServicesImmichCredentials,
      ServerServiceKind.qbittorrent =>
        l10n.serverServicesQbittorrentCredentials,
      ServerServiceKind.adguard => l10n.serverServicesAdguardCredentials,
      ServerServiceKind.keenetic => l10n.serverServicesKeeneticCredentials,
      ServerServiceKind.proxmox => l10n.serverServicesProxmoxCredentials,
      ServerServiceKind.frigate => l10n.serverServicesFrigateCredentials,
      ServerServiceKind.esphome => l10n.serverServicesEsphomeCredentials,
      _ => l10n.serverServicesApiKeyCredentials,
    };

String _authLabel(AppLocalizations l10n, ServerServiceAuthMethod method) =>
    switch (method) {
      ServerServiceAuthMethod.none => l10n.serverServicesNoCredentials,
      ServerServiceAuthMethod.apiKey => l10n.serverServicesApiKey,
      ServerServiceAuthMethod.token => l10n.serverServicesToken,
      ServerServiceAuthMethod.usernamePassword =>
        l10n.serverServicesUsernamePassword,
    };

enum _CredentialMode { keep, replace, clear }

class _ServiceDraft {
  const _ServiceDraft(this.name, this.kind, this.baseUrl, this.credentials);
  final String name, baseUrl;
  final ServerServiceKind kind;
  final Map<String, String>? credentials;
  @override
  String toString() => 'Service draft';
}

class _ServiceForm extends StatefulWidget {
  const _ServiceForm({
    required this.current,
    required this.registerClear,
    this.service,
  });
  final bool Function() current;
  final void Function(VoidCallback) registerClear;
  final ServerService? service;
  @override
  State<_ServiceForm> createState() => _ServiceFormState();
}

class _ServiceFormState extends State<_ServiceForm> {
  late final TextEditingController _name, _url;
  final _credentials = {
    for (final key in serviceCredentialKeys) key: TextEditingController(),
  };
  late ServerServiceKind _kind;
  late _CredentialMode _mode;
  late ServerServiceAuthMethod _authMethod;
  bool _showKinds = false, _submitted = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.service?.name);
    _url = TextEditingController(text: widget.service?.baseUrl);
    _kind = widget.service?.kind ?? ServerServiceKind.homeAssistant;
    final savedKeys = widget.service?.credentialKeys ?? const <String>[];
    _authMethod = serviceAuthMethods(_kind).firstWhere(
      (method) =>
          savedKeys.length == method.credentialKeys.length &&
          method.credentialKeys.every(savedKeys.contains),
      orElse: () => serviceAuthMethods(_kind).first,
    );
    _mode = widget.service == null
        ? _CredentialMode.replace
        : _CredentialMode.keep;
    widget.registerClear(_clear);
  }

  void _clear() {
    if (!mounted) return;
    _name.clear();
    _url.clear();
    _clearCredentials();
  }

  void _clearCredentials() {
    for (final controller in _credentials.values) {
      controller.clear();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    for (final controller in _credentials.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_submitted || !widget.current()) return;
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    String endpoint;
    try {
      endpoint = serviceEndpoint(_url.text.trim());
    } catch (_) {
      setState(() => _failure = l10n.serverIncomplete);
      return;
    }
    Map<String, String>? credentials = switch (_mode) {
      _CredentialMode.keep => null,
      _CredentialMode.clear => {},
      _CredentialMode.replace => {
        for (final key in _authMethod.credentialKeys)
          if (_credentials[key]!.text.isNotEmpty) key: _credentials[key]!.text,
      },
    };
    if (!validServiceName(name) ||
        (credentials != null && !validServiceCredentials(credentials))) {
      setState(() => _failure = l10n.serverIncomplete);
      return;
    }
    if (credentials != null &&
        !validServiceCredentialCombination(_kind, credentials)) {
      setState(() => _failure = l10n.serverServicesCredentialPairRequired);
      return;
    }
    if (widget.service != null &&
        credentials == null &&
        endpoint != widget.service!.baseUrl) {
      setState(() => _failure = l10n.serverServicesEndpointCredentials);
      return;
    }
    final draft = _ServiceDraft(name, _kind, endpoint, credentials);
    _submitted = true;
    _clear();
    Navigator.pop(context, draft);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 600,
            maxHeight: MediaQuery.sizeOf(context).height * .88,
          ),
          child: CupertinoPopupSurface(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    widget.service == null
                        ? l10n.serverServicesAdd
                        : l10n.commonEdit,
                    style: AppText.headline,
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _field(
                          l10n.serverServicesName,
                          'service-name',
                          _name,
                          max: 80,
                        ),
                        if (widget.service == null) ...[
                          Text(l10n.serverServicesKind, style: AppText.subhead),
                          CupertinoButton(
                            key: const ValueKey('service-kind'),
                            onPressed: () {
                              if (widget.current()) {
                                setState(() => _showKinds = !_showKinds);
                              }
                            },
                            child: Text(_kind.label),
                          ),
                          if (_showKinds)
                            Wrap(
                              children: [
                                for (final kind in ServerServiceKind.values)
                                  Semantics(
                                    selected: _kind == kind,
                                    child: CupertinoButton(
                                      key: ValueKey(
                                        'service-kind-${kind.wireName}',
                                      ),
                                      onPressed: () {
                                        if (widget.current()) {
                                          setState(() {
                                            if (_kind != kind) {
                                              _clearCredentials();
                                              _authMethod = serviceAuthMethods(
                                                kind,
                                              ).first;
                                              _failure = null;
                                            }
                                            _kind = kind;
                                            _showKinds = false;
                                          });
                                        }
                                      },
                                      child: Text(kind.label),
                                    ),
                                  ),
                              ],
                            ),
                        ] else
                          Text(_kind.label, style: AppText.subhead),
                        _field(
                          l10n.serverUrl,
                          'service-url',
                          _url,
                          max: 2048,
                          keyboard: TextInputType.url,
                        ),
                        Text(
                          l10n.serverServicesCredentials,
                          style: AppText.headline,
                        ),
                        const SizedBox(height: 8),
                        Text(_credentialGuide(l10n, _kind)),
                        const SizedBox(height: 8),
                        Text(l10n.serverServicesCredentialsHint),
                        if (widget.service
                            case final ServerService service) ...[
                          const SizedBox(height: 8),
                          Text(
                            service.credentialKeys.isEmpty
                                ? l10n.serverServicesNoCredentials
                                : '${l10n.serverServicesSavedCredentials}: ${service.credentialKeys.map((key) => _credentialLabel(l10n, key)).join(', ')}',
                            key: const ValueKey(
                              'service-saved-credential-fields',
                            ),
                            style: AppText.footnote,
                          ),
                          if (!validServiceCredentialCombination(_kind, {
                            for (final key in service.credentialKeys) key: '',
                          }))
                            Text(
                              l10n.serverServicesSavedCredentialsUnsupported,
                              style: AppText.footnote,
                            ),
                        ],
                        if (widget.service != null)
                          Wrap(
                            children: [
                              for (final mode in _CredentialMode.values)
                                if (mode != _CredentialMode.replace ||
                                    _authMethod != ServerServiceAuthMethod.none)
                                  Semantics(
                                    selected: _mode == mode,
                                    child: CupertinoButton(
                                      key: ValueKey(
                                        'service-credentials-${mode.name}',
                                      ),
                                      color: _mode == mode
                                          ? CupertinoColors.tertiarySystemFill
                                                .resolveFrom(context)
                                          : null,
                                      onPressed: () {
                                        if (!widget.current()) return;
                                        setState(() {
                                          _mode = mode;
                                          _failure = null;
                                          if (mode != _CredentialMode.replace) {
                                            _clearCredentials();
                                          }
                                        });
                                      },
                                      child: Text(switch (mode) {
                                        _CredentialMode.keep =>
                                          l10n.serverServicesKeepCredentials,
                                        _CredentialMode.replace =>
                                          l10n.serverServicesReplaceCredentials,
                                        _CredentialMode.clear =>
                                          l10n.serverServicesClearCredentials,
                                      }),
                                    ),
                                  ),
                            ],
                          ),
                        if (_mode == _CredentialMode.replace &&
                            serviceAuthMethods(_kind).length > 1) ...[
                          const SizedBox(height: 8),
                          Text(
                            l10n.serverServicesAuthMethod,
                            style: AppText.subhead,
                          ),
                          Wrap(
                            children: [
                              for (final method in serviceAuthMethods(_kind))
                                Semantics(
                                  selected: _authMethod == method,
                                  child: CupertinoButton(
                                    key: ValueKey(
                                      'service-auth-${method.name}',
                                    ),
                                    color: _authMethod == method
                                        ? CupertinoColors.tertiarySystemFill
                                              .resolveFrom(context)
                                        : null,
                                    onPressed: () {
                                      if (!widget.current() ||
                                          _authMethod == method) {
                                        return;
                                      }
                                      setState(() {
                                        _clearCredentials();
                                        _authMethod = method;
                                        _failure = null;
                                      });
                                    },
                                    child: Text(_authLabel(l10n, method)),
                                  ),
                                ),
                            ],
                          ),
                        ],
                        if (_mode == _CredentialMode.replace)
                          for (final key in _authMethod.credentialKeys)
                            _field(
                              _credentialLabel(l10n, key),
                              'service-credential-$key',
                              _credentials[key]!,
                              secret: true,
                              max: 2048,
                            ),
                        if (_failure != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                _failure!,
                                style: TextStyle(
                                  color: CupertinoColors.systemRed.resolveFrom(
                                    context,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      CupertinoButton(
                        onPressed: () {
                          if (widget.current() && !_submitted) {
                            _clear();
                            Navigator.pop(context);
                          }
                        },
                        child: Text(l10n.commonCancel),
                      ),
                      CupertinoButton(
                        key: const ValueKey('service-submit'),
                        onPressed: _submit,
                        child: Text(l10n.commonSave),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    String label,
    String key,
    TextEditingController controller, {
    bool secret = false,
    required int max,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: AppText.subhead),
        const SizedBox(height: 8),
        Semantics(
          label: label,
          child: CupertinoTextField(
            key: ValueKey(key),
            controller: controller,
            obscureText: secret,
            maxLength: max,
            keyboardType: keyboard,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            padding: const EdgeInsets.all(12),
          ),
        ),
      ],
    ),
  );
}
