import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../providers/server_providers.dart';
import '../data/server_admin_controller.dart';
import '../domain/server_admin_models.dart';

class ServerAdminScreen extends ConsumerStatefulWidget {
  const ServerAdminScreen({super.key});
  @override
  ConsumerState<ServerAdminScreen> createState() => _ServerAdminScreenState();
}

class _ServerAdminScreenState extends MediaSessionState<ServerAdminScreen> {
  late final ServerAccountController _account;
  late final ServerAdminController _admin;
  late int _accountEpoch;
  AdminTab _tab = AdminTab.users;
  Route<Object?>? _dialog;
  VoidCallback? _clearSecret;
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true, _expired = false, _loaded = false, _pinReady = false;
  bool _wasCurrent = true;

  bool get _active =>
      !_expired &&
      _visible &&
      _pinReady &&
      sessionCurrent(sessionGeneration) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      (ModalRoute.of(context)?.isCurrent == true || _dialog?.isCurrent == true);
  bool get _enabled =>
      _active && !_admin.busy && !_admin.needsRefresh && _admin.failure == null;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _admin = ServerAdminController(_account);
    _account.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (_accountEpoch != _account.generation ||
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
    final wasBusy = _admin.busy;
    _expired = true;
    sessionGeneration++;
    final clearSecret = _clearSecret;
    _clearSecret = null;
    final route = _dialog;
    _dialog = null;
    void clearVisibleState() {
      if (!mounted) return;
      if (route?.isActive == true) {
        clearSecret?.call();
        route!.navigator?.removeRoute(route);
      }
      _admin.invalidate();
    }

    // TickerMode may change while a sibling dialog is being built. Revoke
    // authorization now, then update that dialog outside the build phase.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => clearVisibleState());
    } else {
      clearVisibleState();
    }
    // A refresh awaited by this screen is also bound to its visible account
    // context. Cancelling it sends no remote logout or administrator mutation.
    if (wasBusy && !_account.working) unawaited(_account.cancelPending());
  }

  @override
  void dispose() {
    // The form owns and disposes its text controllers. Notifying one while
    // Navigator descendants are inactive would access a detached editor.
    _clearSecret = null;
    _account.removeListener(_accountChanged);
    _ticker?.removeListener(_visibilityChanged);
    _admin.dispose();
    super.dispose();
  }

  bool Function() _capture() {
    final epoch = sessionGeneration, accountEpoch = _account.generation;
    return () =>
        mounted &&
        sessionCurrent(epoch) &&
        _active &&
        _account.isCurrent(accountEpoch);
  }

  VoidCallback _callback(VoidCallback action) {
    final current = _capture();
    return () {
      if (current()) action();
    };
  }

  Future<void> _load({bool more = false}) async {
    if (!_active || _admin.busy || _dialog != null) return;
    await _admin.load(_tab, current: _capture(), more: more);
  }

  void _select(AdminTab tab) {
    if (!_active || _admin.busy || _dialog != null || _tab == tab) return;
    setState(() => _tab = tab);
    _admin.invalidate();
    unawaited(_load());
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
    _clearSecret = null;
    if (!current()) return null;
    return result;
  }

  Future<void> _create() async {
    final current = _capture();
    final draft = await _show<_UserDraft>(
      (context, valid) => _UserForm(
        current: valid,
        registerClear: (clear) => _clearSecret = clear,
      ),
    );
    if (draft == null || !current()) return;
    await _admin.create(
      username: draft.username,
      role: draft.role,
      password: draft.password,
      current: current,
    );
  }

  Future<void> _edit(AdminUser user) async {
    final current = _capture();
    final draft = await _show<_AccessDraft>(
      (context, valid) => _AccessForm(user: user, current: valid),
    );
    if (draft == null || !current()) return;
    await _admin.update(
      user,
      role: draft.role,
      disabled: draft.disabled,
      current: current,
    );
  }

  Future<void> _reset(AdminUser user) async {
    if (user.id == _account.session?.user.id) return;
    final current = _capture();
    final draft = await _show<_UserDraft>(
      (context, valid) => _UserForm(
        user: user,
        current: valid,
        registerClear: (clear) => _clearSecret = clear,
      ),
    );
    if (draft == null || !current()) return;
    await _admin.resetPassword(user, draft.password, current: current);
  }

  Future<void> _revoke(AdminDeviceSession session) async {
    final current = _capture();
    final accepted = await _show<bool>((context, valid) {
      final l10n = AppLocalizations.of(context);
      return CupertinoAlertDialog(
        title: Text(l10n.serverAdminRevoke),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(session.deviceName),
            const SizedBox(height: 8),
            Text(l10n.serverAdminRevokeHint),
          ],
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () {
              if (valid()) Navigator.pop(context, false);
            },
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('admin-confirm-revoke'),
            isDestructiveAction: true,
            onPressed: () {
              if (valid()) Navigator.pop(context, true);
            },
            child: Text(l10n.serverAdminRevoke),
          ),
        ],
      );
    });
    if (accepted != true || !current()) return;
    await _admin.revoke(session, current: current);
  }

  String _failure(AppLocalizations l10n) => switch (_admin.failure) {
    'last_active_admin' => l10n.serverAdminLastAdmin,
    'conflict' || 'revision_conflict' => l10n.serverAdminConflict,
    'username_unavailable' => l10n.serverAdminUsernameTaken,
    'user_limit_reached' => l10n.serverAdminUserLimit,
    'self_password_reset_forbidden' => l10n.serverAdminOwnReset,
    'forbidden' || 'password_change_required' => l10n.serverFailurePermission,
    'unauthorized' => l10n.serverFailureAuthentication,
    'invalid_request' => l10n.serverIncomplete,
    'rate_limited' => l10n.serverFailureRateLimit,
    _ =>
      _admin.needsRefresh
          ? l10n.serverAdminUncertain
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
          l10n.serverAdminTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _admin,
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
            final count = switch (_tab) {
              AdminTab.users => _admin.users.length,
              AdminTab.sessions => _admin.sessions.length,
              AdminTab.audit => _admin.audit.length,
            };
            final hasMore = switch (_tab) {
              AdminTab.users => false,
              AdminTab.sessions => _admin.sessionsCursor != null,
              AdminTab.audit => _admin.auditCursor != null,
            };
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: ListView.builder(
                  key: const ValueKey('admin-list'),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  itemCount: count + 2,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Text(l10n.serverAdminIntro),
                          ),
                          SettingsSection(
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Wrap(
                                  spacing: 4,
                                  children: [
                                    for (final tab in AdminTab.values)
                                      Semantics(
                                        selected: _tab == tab,
                                        child: CupertinoButton(
                                          key: ValueKey(
                                            'admin-tab-${tab.name}',
                                          ),
                                          color: _tab == tab
                                              ? CupertinoColors
                                                    .tertiarySystemFill
                                                    .resolveFrom(context)
                                              : null,
                                          onPressed: !_admin.busy
                                              ? _callback(() => _select(tab))
                                              : null,
                                          child: Text(switch (tab) {
                                            AdminTab.users =>
                                              l10n.serverAdminUsers,
                                            AdminTab.sessions =>
                                              l10n.serverAdminSessions,
                                            AdminTab.audit =>
                                              l10n.serverAdminAudit,
                                          }),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              CupertinoButton(
                                key: const ValueKey('admin-refresh'),
                                onPressed: !_admin.busy
                                    ? _callback(_load)
                                    : null,
                                child: Text(l10n.serverAdminRefresh),
                              ),
                              if (_tab == AdminTab.users)
                                CupertinoButton(
                                  key: const ValueKey('admin-create'),
                                  onPressed: _enabled
                                      ? _callback(_create)
                                      : null,
                                  child: Text(l10n.serverAdminCreate),
                                ),
                            ],
                          ),
                          if (_admin.busy)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(
                                child: CupertinoActivityIndicator(),
                              ),
                            ),
                          if (_admin.failure != null || _admin.changed)
                            Padding(
                              padding: const EdgeInsets.all(20),
                              child: Semantics(
                                liveRegion: true,
                                child: Text(
                                  _admin.failure != null
                                      ? _failure(l10n)
                                      : l10n.serverAdminActionDone,
                                ),
                              ),
                            ),
                          if (count == 0 &&
                              !_admin.busy &&
                              _admin.failure == null)
                            Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(l10n.serverAdminEmpty),
                            ),
                        ],
                      );
                    }
                    if (index == count + 1) {
                      return count >= ServerAdminController.maxVisibleEntries
                          ? Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(l10n.serverAdminLimit),
                            )
                          : hasMore
                          ? CupertinoButton(
                              key: const ValueKey('admin-more'),
                              onPressed: _enabled
                                  ? _callback(() => _load(more: true))
                                  : null,
                              child: Text(l10n.serverAdminMore),
                            )
                          : const SizedBox(height: 20);
                    }
                    return switch (_tab) {
                      AdminTab.users => _user(l10n, _admin.users[index - 1]),
                      AdminTab.sessions => _session(
                        l10n,
                        _admin.sessions[index - 1],
                      ),
                      AdminTab.audit => _event(l10n, _admin.audit[index - 1]),
                    };
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _card(List<Widget> children, {Key? key}) => SettingsSection(
    key: key,
    margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
    children: [
      Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ],
  );

  Widget _user(AppLocalizations l10n, AdminUser user) => _card([
    Text(user.username, style: AppText.headline),
    Text(
      user.role == ServerRole.admin
          ? l10n.serverAdministrator
          : l10n.serverMember,
    ),
    Text(user.disabled ? l10n.serverAdminDisabled : l10n.serverAdminEnabled),
    if (user.mustChangePassword) Text(l10n.serverPasswordRequired),
    Text(
      '${l10n.serverAdminRevision}: ${user.revision}',
      style: AppText.footnote,
    ),
    Wrap(
      children: [
        CupertinoButton(
          key: ValueKey('admin-edit-${user.id}'),
          onPressed: _enabled ? _callback(() => _edit(user)) : null,
          child: Text(l10n.serverAdminEdit),
        ),
        CupertinoButton(
          key: ValueKey('admin-reset-${user.id}'),
          onPressed: _enabled && user.id != _account.session?.user.id
              ? _callback(() => _reset(user))
              : null,
          child: Text(l10n.serverAdminReset),
        ),
      ],
    ),
    if (user.id == _account.session?.user.id)
      Text(l10n.serverAdminOwnReset, style: AppText.footnote),
  ], key: ValueKey('admin-user-${user.id}'));

  Widget _session(AppLocalizations l10n, AdminDeviceSession session) => _card([
    Text(session.deviceName, style: AppText.headline),
    Text(switch (session.status) {
      AdminSessionStatus.active => l10n.serverAdminActive,
      AdminSessionStatus.revoked => l10n.serverAdminRevoked,
      AdminSessionStatus.expired => l10n.serverAdminExpired,
    }),
    Text(
      '${l10n.serverAdminUserId}: ${session.userId}',
      style: AppText.footnote,
    ),
    Text('${l10n.serverAdminCreatedAt}: ${_date(session.createdAt)}'),
    Text('${l10n.serverAdminExpiresAt}: ${_date(session.expiresAt)}'),
    if (session.status == AdminSessionStatus.active)
      CupertinoButton(
        key: ValueKey('admin-revoke-${session.id}'),
        onPressed: _enabled ? _callback(() => _revoke(session)) : null,
        child: Text(l10n.serverAdminRevoke),
      ),
  ]);

  Widget _event(AppLocalizations l10n, AdminAuditEvent event) => _card([
    Text(switch (event.action) {
      AdminAuditAction.create => l10n.serverAdminCreateEvent,
      AdminAuditAction.update => l10n.serverAdminUpdateEvent,
      AdminAuditAction.resetPassword => l10n.serverAdminResetEvent,
      AdminAuditAction.revoke => l10n.serverAdminRevokeEvent,
    }, style: AppText.headline),
    Text(event.succeeded ? l10n.serverAdminSucceeded : l10n.serverAdminDenied),
    Text(_date(event.timestamp)),
    Text(
      '${l10n.serverAdminActorId}: ${event.actorId}',
      style: AppText.footnote,
    ),
    if (event.targetId != null)
      Text(
        '${l10n.serverAdminUserId}: ${event.targetId}',
        style: AppText.footnote,
      ),
  ]);

  String _date(DateTime value) =>
      '${value.toUtc().toIso8601String().substring(0, 16).replaceFirst('T', ' ')} UTC';
}

class _UserDraft {
  const _UserDraft(this.username, this.role, this.password);
  final String username, password;
  final ServerRole role;
}

class _UserForm extends StatefulWidget {
  const _UserForm({
    required this.current,
    required this.registerClear,
    this.user,
  });
  final bool Function() current;
  final void Function(VoidCallback) registerClear;
  final AdminUser? user;
  @override
  State<_UserForm> createState() => _UserFormState();
}

class _UserFormState extends State<_UserForm> {
  final _username = TextEditingController(),
      _password = TextEditingController();
  ServerRole _role = ServerRole.member;
  bool _invalid = false, _submitted = false;
  @override
  void initState() {
    super.initState();
    widget.registerClear(_password.clear);
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_submitted || !widget.current()) return;
    final username = widget.user?.username ?? _username.text.trim();
    if (!validAdminUsername(username) || !validAdminPassword(_password.text)) {
      setState(() => _invalid = true);
      return;
    }
    final draft = _UserDraft(username, _role, _password.text);
    _password.clear();
    _submitted = true;
    Navigator.pop(context, draft);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final resetting = widget.user != null;
    return CupertinoAlertDialog(
      title: Text(resetting ? l10n.serverAdminReset : l10n.serverAdminCreate),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (resetting) ...[
            Text(widget.user!.username),
            Text('${l10n.serverAdminRevision}: ${widget.user!.revision}'),
            Text(l10n.serverAdminResetHint),
          ] else ...[
            _field(l10n.serverUsername, 'admin-username', _username, max: 64),
            Wrap(
              children: [
                for (final role in ServerRole.values)
                  Semantics(
                    selected: _role == role,
                    child: CupertinoButton(
                      key: ValueKey('admin-role-${role.name}'),
                      onPressed: () {
                        if (widget.current()) setState(() => _role = role);
                      },
                      child: Text(
                        role == ServerRole.admin
                            ? l10n.serverAdministrator
                            : l10n.serverMember,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          _field(
            l10n.serverAdminTemporaryPassword,
            'admin-temporary-password',
            _password,
            secret: true,
          ),
          Text(l10n.serverAdminTemporaryHint),
          if (_invalid)
            Text(
              l10n.serverPasswordInvalid,
              style: TextStyle(
                color: CupertinoColors.systemRed.resolveFrom(context),
              ),
            ),
          if (!resetting) Text(l10n.serverAdminConfirmCreate),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () {
            if (widget.current()) {
              _password.clear();
              Navigator.pop(context);
            }
          },
          child: Text(l10n.commonCancel),
        ),
        CupertinoDialogAction(
          key: const ValueKey('admin-submit-user'),
          onPressed: _submit,
          isDestructiveAction: resetting,
          child: Text(
            resetting ? l10n.serverAdminReset : l10n.serverAdminCreate,
          ),
        ),
      ],
    );
  }

  Widget _field(
    String label,
    String key,
    TextEditingController controller, {
    bool secret = false,
    int max = 128,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label),
        const SizedBox(height: 6),
        Semantics(
          label: label,
          child: CupertinoTextField(
            key: ValueKey(key),
            controller: controller,
            obscureText: secret,
            maxLength: max,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !_submitted,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) {
              if (widget.current()) FocusScope.of(context).nextFocus();
            },
          ),
        ),
      ],
    ),
  );
}

class _AccessDraft {
  const _AccessDraft(this.role, this.disabled);
  final ServerRole role;
  final bool disabled;
}

class _AccessForm extends StatefulWidget {
  const _AccessForm({required this.user, required this.current});
  final AdminUser user;
  final bool Function() current;
  @override
  State<_AccessForm> createState() => _AccessFormState();
}

class _AccessFormState extends State<_AccessForm> {
  late ServerRole _role = widget.user.role;
  late bool _disabled = widget.user.disabled;
  bool _submitted = false;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CupertinoAlertDialog(
      title: Text(l10n.serverAdminEdit),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.user.username),
          Text('${l10n.serverAdminRevision}: ${widget.user.revision}'),
          Text(l10n.serverAdminAccessHint),
          Wrap(
            children: [
              for (final role in ServerRole.values)
                Semantics(
                  selected: _role == role,
                  child: CupertinoButton(
                    key: ValueKey('admin-access-role-${role.name}'),
                    onPressed: () {
                      if (widget.current()) setState(() => _role = role);
                    },
                    child: Text(
                      role == ServerRole.admin
                          ? l10n.serverAdministrator
                          : l10n.serverMember,
                    ),
                  ),
                ),
            ],
          ),
          MergeSemantics(
            child: Column(
              children: [
                Text(
                  _disabled
                      ? l10n.serverAdminDisabled
                      : l10n.serverAdminEnabled,
                ),
                CupertinoSwitch(
                  key: const ValueKey('admin-access-disabled'),
                  value: _disabled,
                  onChanged: (value) {
                    if (widget.current()) setState(() => _disabled = value);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () {
            if (widget.current()) Navigator.pop(context);
          },
          child: Text(l10n.commonCancel),
        ),
        CupertinoDialogAction(
          key: const ValueKey('admin-submit-access'),
          isDestructiveAction: _disabled || _role == ServerRole.member,
          onPressed: () {
            if (_submitted || !widget.current()) return;
            _submitted = true;
            Navigator.pop(context, _AccessDraft(_role, _disabled));
          },
          child: Text(l10n.serverAdminSave),
        ),
      ],
    );
  }
}
