import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../core/home_session_controller.dart';
import '../../home_scope/presentation/home_source_screen.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../client_updates/presentation/client_updates_screen.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../../settings/providers/settings_providers.dart';
import '../admin/presentation/server_admin_screen.dart';
import '../data/server_account_controller.dart';
import '../domain/server_models.dart';
import '../plugins/presentation/server_plugins_screen.dart';
import '../providers/server_providers.dart';
import '../services/presentation/server_services_screen.dart';
import 'server_vault_screen.dart';

/// Account management is reached through SettingsGate. First-install access
/// additionally observes PIN storage and fails closed if a PIN appears.
class ServerConnectionScreen extends ConsumerStatefulWidget {
  const ServerConnectionScreen({
    super.key,
    this.freshInstall = false,
    this.onExit,
  });
  final bool freshInstall;
  final VoidCallback? onExit;
  @override
  ConsumerState<ServerConnectionScreen> createState() =>
      _ServerConnectionScreenState();
}

class _ServerConnectionScreenState
    extends MediaSessionState<ServerConnectionScreen> {
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _device = TextEditingController(text: 'Larenor tablet');
  final _currentPassword = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  late final ServerAccountController _account;
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true;
  bool _ownedOperation = false;
  bool _editPassword = false;
  bool _pinAllowed = false;
  Route<bool>? _dialog;
  String? _message;
  bool _messageError = false;
  bool _wasCurrent = true;
  bool _invokingAccount = false;
  int _knownAccountGeneration = 0;

  bool get _active =>
      sessionCurrent(sessionGeneration) &&
      _visible &&
      (ModalRoute.of(context)?.isCurrent == true ||
          _dialog?.isCurrent == true) &&
      (!widget.freshInstall || _pinAllowed);
  bool get _enabled =>
      _active && !_ownedOperation && !_account.working && _account.initialized;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _knownAccountGeneration = _account.generation;
    _account.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _active) _initialize();
    });
  }

  void _accountChanged() {
    if (!mounted || _knownAccountGeneration == _account.generation) return;
    _knownAccountGeneration = _account.generation;
    if (!_invokingAccount) _invalidate(cancelOwned: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = TickerMode.getValuesNotifier(context);
    if (!identical(next, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = next;
      _visible = next.value.enabled;
      next.addListener(_visibilityChanged);
    }
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_wasCurrent && !current && _dialog == null) _invalidate();
    _wasCurrent = current;
  }

  void _visibilityChanged() {
    if (!mounted) return;
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _invalidate();
    setState(() {});
  }

  @override
  void clearPendingInteraction() => _invalidate();

  void _clearPasswords() {
    _password.clear();
    _currentPassword.clear();
    _newPassword.clear();
    _confirmPassword.clear();
  }

  void _invalidate({bool cancelOwned = true}) {
    sessionGeneration++;
    _clearPasswords();
    _message = null;
    _editPassword = false;
    final route = _dialog;
    _dialog = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
    if (_ownedOperation) {
      _ownedOperation = false;
      if (cancelOwned) unawaited(_account.cancelPending());
    }
  }

  @override
  void dispose() {
    _account.removeListener(_accountChanged);
    _invalidate();
    _ticker?.removeListener(_visibilityChanged);
    for (final controller in [
      _url,
      _username,
      _password,
      _device,
      _currentPassword,
      _newPassword,
      _confirmPassword,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _initialize() async {
    if (!mounted || !_active || _ownedOperation || _account.working) return;
    await _run(_account.initialize);
  }

  Future<void> _run(
    Future<void> Function() operation, {
    bool passwordChanged = false,
  }) async {
    if (!_active || _ownedOperation || _account.working) return;
    final epoch = sessionGeneration;
    setState(() {
      _ownedOperation = true;
      _message = null;
    });
    try {
      _invokingAccount = true;
      final Future<void> pending;
      try {
        pending = operation();
      } finally {
        _invokingAccount = false;
      }
      await pending;
      if (!mounted || !sessionCurrent(epoch) || !_active) return;
      if (passwordChanged &&
          _account.failure == null &&
          _account.session?.user.mustChangePassword == false) {
        setState(() {
          _editPassword = false;
          _message = AppLocalizations.of(context).serverPasswordChanged;
          _messageError = false;
        });
      }
    } catch (_) {
      if (mounted && sessionCurrent(epoch) && _active) {
        setState(() {
          _message = AppLocalizations.of(context).serverFailureUnknown;
          _messageError = true;
        });
      }
    } finally {
      if (mounted && sessionCurrent(epoch)) {
        setState(() => _ownedOperation = false);
      }
    }
  }

  Future<void> _signIn() async {
    if (!_enabled) return;
    final l10n = AppLocalizations.of(context);
    if (_url.text.trim().isEmpty ||
        _username.text.trim().isEmpty ||
        _password.text.isEmpty ||
        _device.text.trim().isEmpty) {
      setState(() {
        _message = l10n.serverIncomplete;
        _messageError = true;
      });
      return;
    }
    final password = _password.text;
    _password.clear();
    await _run(
      () => _account.signIn(
        baseUrl: _url.text.trim(),
        username: _username.text.trim(),
        password: password,
        deviceName: _device.text.trim(),
      ),
    );
  }

  VoidCallback _callback(VoidCallback action) {
    final epoch = sessionGeneration;
    final accountGeneration = _account.generation;
    return () {
      if (sessionCurrent(epoch) &&
          _active &&
          _account.isCurrent(accountGeneration)) {
        action();
      }
    };
  }

  Future<void> _changePassword() async {
    if (!_enabled) return;
    final next = _newPassword.text;
    if (_currentPassword.text.isEmpty ||
        next.runes.length < 12 ||
        next.runes.length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(next) ||
        next != _confirmPassword.text) {
      setState(() {
        _message = AppLocalizations.of(context).serverPasswordInvalid;
        _messageError = true;
      });
      return;
    }
    final current = _currentPassword.text;
    _clearPasswords();
    await _run(
      () =>
          _account.changePassword(currentPassword: current, newPassword: next),
      passwordChanged: true,
    );
  }

  Future<void> _signOut() async {
    if (!_enabled || _dialog != null) return;
    final epoch = sessionGeneration;
    final accountGeneration = _account.generation;
    final l10n = AppLocalizations.of(context);
    final route = CupertinoDialogRoute<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.serverSignOutConfirm),
        content: Text(l10n.serverSignOutHint),
        actions: [
          CupertinoDialogAction(
            onPressed: () {
              if (context.mounted &&
                  ModalRoute.of(context)?.isCurrent == true) {
                Navigator.pop(context, false);
              }
            },
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              if (context.mounted &&
                  ModalRoute.of(context)?.isCurrent == true &&
                  sessionCurrent(epoch) &&
                  _active &&
                  _account.isCurrent(accountGeneration)) {
                Navigator.pop(context, true);
              }
            },
            child: Text(l10n.serverSignOut),
          ),
        ],
      ),
    );
    _dialog = route;
    final accepted = await Navigator.of(context).push(route);
    if (identical(_dialog, route)) _dialog = null;
    if (!mounted ||
        !sessionCurrent(epoch) ||
        !_active ||
        !_account.isCurrent(accountGeneration) ||
        accepted != true) {
      return;
    }
    _clearPasswords();
    await _run(_account.signOut);
  }

  String _failure(AppLocalizations l10n, String code) => switch (code) {
    'unauthorized' ||
    'invalid_credentials' ||
    'invalid_session' => l10n.serverFailureAuthentication,
    'forbidden' || 'password_change_required' => l10n.serverFailurePermission,
    'storage_failed' => l10n.serverFailureStorage,
    'rate_limited' => l10n.serverFailureRateLimit,
    'cancelled' => l10n.serverFailureCancelled,
    'logout_not_confirmed' => l10n.serverLogoutUnconfirmed,
    'invalid_request' => l10n.serverIncomplete,
    'context_endpoint_unavailable' => l10n.serverContextEndpointUnavailable,
    _ => l10n.serverFailureConnection,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (widget.freshInstall) {
      final pin = ref.watch(pinLockProvider);
      _pinAllowed = !pin.isLoading && !pin.hasError && pin.value == null;
      ref.listen(pinLockProvider, (_, next) {
        if (next.isLoading || next.hasError || next.value != null) {
          _pinAllowed = false;
          _invalidate();
        } else if (!_account.initialized && !_account.working) {
          _pinAllowed = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _active) _initialize();
          });
        }
      });
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        leading: widget.onExit == null
            ? null
            : CupertinoNavigationBarBackButton(
                onPressed: _callback(widget.onExit!),
              ),
        middle: Text(
          l10n.serverTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _account,
          builder: (context, _) {
            if (!_active) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(l10n.serverOpenFromSettings),
                ),
              );
            }
            final session = _account.session;
            final changing =
                session?.user.mustChangePassword == true || _editPassword;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(l10n.serverIntro, style: AppText.body),
                      ),
                      if (ref.watch(homeSessionControllerProvider) != null)
                        SettingsSection(
                          children: [
                            SettingsActionTile(
                              title: Text(l10n.homeSourceTitle),
                              onTap: _active
                                  ? _callback(() {
                                      Navigator.of(context).push(
                                        CupertinoPageRoute<void>(
                                          builder: (_) =>
                                              const HomeSourceScreen(),
                                        ),
                                      );
                                    })
                                  : null,
                            ),
                          ],
                        ),
                      if (!_account.initialized) ...[
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(l10n.serverChecking),
                        ),
                        if (!_account.working)
                          CupertinoButton(
                            onPressed: _callback(_initialize),
                            child: Text(l10n.commonRetry),
                          ),
                      ] else if (_account.hasPendingContext) ...[
                        SettingsSection(
                          header: Text(l10n.serverContextPending),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                l10n.serverContextPendingHint,
                                style: AppText.body,
                              ),
                            ),
                          ],
                        ),
                        _button(
                          'server-context-retry',
                          l10n.serverContextRetry,
                          () => _run(_account.retryContext),
                        ),
                        CupertinoButton(
                          key: const ValueKey('server-sign-out'),
                          onPressed: _enabled && _dialog == null
                              ? _callback(_signOut)
                              : null,
                          child: Text(l10n.serverSignOut),
                        ),
                      ] else if (session == null) ...[
                        SettingsSection(
                          children: [
                            _field(
                              'server-url',
                              l10n.serverUrl,
                              _url,
                              keyboard: TextInputType.url,
                              max: 2048,
                            ),
                            _field(
                              'server-username',
                              l10n.serverUsername,
                              _username,
                              max: 128,
                            ),
                            _field(
                              'server-password',
                              l10n.serverPassword,
                              _password,
                              secret: true,
                              max: 1024,
                            ),
                            _field(
                              'server-device-name',
                              l10n.serverDeviceName,
                              _device,
                              max: 128,
                            ),
                          ],
                        ),
                        _button('server-sign-in', l10n.serverSignIn, _signIn),
                      ] else ...[
                        SettingsSection(
                          header: Text(l10n.serverAccount),
                          children: [
                            _info(l10n.serverUrl, session.endpoint.baseUrl),
                            _info(l10n.serverUsername, session.user.username),
                            _info(
                              l10n.serverRole,
                              session.user.role == ServerRole.admin
                                  ? l10n.serverAdministrator
                                  : l10n.serverMember,
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            changing && session.user.mustChangePassword
                                ? l10n.serverPasswordRequired
                                : l10n.serverConnected,
                            style: AppText.headline,
                          ),
                        ),
                        if (changing) ...[
                          SettingsSection(
                            footer: Text(l10n.serverPasswordHint),
                            children: [
                              _field(
                                'server-current-password',
                                l10n.serverCurrentPassword,
                                _currentPassword,
                                secret: true,
                                max: 1024,
                              ),
                              _field(
                                'server-new-password',
                                l10n.serverNewPassword,
                                _newPassword,
                                secret: true,
                                max: 128,
                              ),
                              _field(
                                'server-confirm-password',
                                l10n.serverConfirmPassword,
                                _confirmPassword,
                                secret: true,
                                max: 128,
                              ),
                            ],
                          ),
                          _button(
                            'server-change-password',
                            l10n.serverChangePassword,
                            _changePassword,
                          ),
                          if (!session.user.mustChangePassword)
                            CupertinoButton(
                              onPressed: _enabled
                                  ? _callback(
                                      () => setState(() {
                                        _editPassword = false;
                                        _clearPasswords();
                                      }),
                                    )
                                  : null,
                              child: Text(l10n.commonCancel),
                            ),
                        ] else
                          CupertinoButton(
                            key: const ValueKey('server-edit-password'),
                            onPressed: _enabled
                                ? _callback(
                                    () => setState(() => _editPassword = true),
                                  )
                                : null,
                            child: Text(l10n.serverChangePassword),
                          ),
                        if (!session.user.mustChangePassword)
                          SettingsSection(
                            children: [
                              if (session.user.canAdminister)
                                CupertinoListTile(
                                  key: const ValueKey('server-admin'),
                                  leading: const Icon(CupertinoIcons.person_2),
                                  title: Text(l10n.serverAdminTitle),
                                  trailing: const CupertinoListTileChevron(),
                                  onTap: _enabled
                                      ? _callback(() {
                                          if (_account
                                                  .session
                                                  ?.user
                                                  .canAdminister !=
                                              true) {
                                            return;
                                          }
                                          Navigator.of(context).push<void>(
                                            CupertinoPageRoute(
                                              builder: (_) =>
                                                  const ServerAdminScreen(),
                                            ),
                                          );
                                        })
                                      : null,
                                ),
                              if (session.user.canAdminister)
                                CupertinoListTile(
                                  key: const ValueKey('server-services'),
                                  leading: const Icon(CupertinoIcons.link),
                                  title: Text(l10n.serverServicesTitle),
                                  trailing: const CupertinoListTileChevron(),
                                  onTap: _enabled
                                      ? _callback(() {
                                          if (_account
                                                  .session
                                                  ?.user
                                                  .canAdminister !=
                                              true) {
                                            return;
                                          }
                                          Navigator.of(context).push<void>(
                                            CupertinoPageRoute(
                                              builder: (_) =>
                                                  const ServerServicesScreen(),
                                            ),
                                          );
                                        })
                                      : null,
                                ),
                              if (session.user.canAdminister)
                                CupertinoListTile(
                                  key: const ValueKey('server-plugins'),
                                  leading: const Icon(CupertinoIcons.cube_box),
                                  title: Text(l10n.serverPluginsTitle),
                                  trailing: const CupertinoListTileChevron(),
                                  onTap: _enabled
                                      ? _callback(() {
                                          if (_account
                                                  .session
                                                  ?.user
                                                  .canAdminister !=
                                              true) {
                                            return;
                                          }
                                          Navigator.of(context).push<void>(
                                            CupertinoPageRoute(
                                              builder: (_) =>
                                                  const ServerPluginsScreen(),
                                            ),
                                          );
                                        })
                                      : null,
                                ),
                              SettingsActionTile(
                                key: const ValueKey('server-vault'),
                                leading: const Icon(CupertinoIcons.lock_shield),
                                title: Text(l10n.serverVaultTitle),
                                onTap: _enabled
                                    ? _callback(
                                        () => Navigator.of(context).push<void>(
                                          CupertinoPageRoute(
                                            builder: (_) => ServerVaultScreen(
                                              freshInstall: widget.freshInstall,
                                            ),
                                          ),
                                        ),
                                      )
                                    : null,
                              ),
                              SettingsActionTile(
                                key: const ValueKey('server-client-updates'),
                                leading: const Icon(
                                  CupertinoIcons.arrow_down_circle,
                                ),
                                title: Text(l10n.clientUpdatesTitle),
                                onTap: _enabled
                                    ? _callback(
                                        () => Navigator.of(context).push<void>(
                                          CupertinoPageRoute(
                                            builder: (_) =>
                                                const ClientUpdatesScreen(),
                                          ),
                                        ),
                                      )
                                    : null,
                              ),
                            ],
                          ),
                        CupertinoButton(
                          key: const ValueKey('server-sign-out'),
                          onPressed: _enabled && _dialog == null
                              ? _callback(_signOut)
                              : null,
                          child: Text(l10n.serverSignOut),
                        ),
                      ],
                      if (_account.working || _ownedOperation)
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: Center(child: CupertinoActivityIndicator()),
                        ),
                      if (_message != null || _account.failure != null)
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              _message ?? _failure(l10n, _account.failure!),
                              style: TextStyle(
                                color:
                                    (_messageError || _account.failure != null)
                                    ? CupertinoColors.systemRed.resolveFrom(
                                        context,
                                      )
                                    : CupertinoColors.label.resolveFrom(
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
            );
          },
        ),
      ),
    );
  }

  Widget _field(
    String key,
    String label,
    TextEditingController controller, {
    bool secret = false,
    int max = 128,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.all(12),
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
            enabled: _enabled,
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
  Widget _info(String label, String value) => Padding(
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: AppText.footnote),
        const SizedBox(height: 4),
        Text(value, style: AppText.body),
      ],
    ),
  );
  Widget _button(String key, String text, VoidCallback action) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    child: CupertinoButton.filled(
      key: ValueKey(key),
      onPressed: _enabled ? _callback(action) : null,
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}
