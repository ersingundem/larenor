import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_support_sessions_controller.dart';
import '../domain/server_support_session_models.dart';

class ServerSupportSessionsScreen extends ConsumerStatefulWidget {
  const ServerSupportSessionsScreen({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;

  @override
  ConsumerState<ServerSupportSessionsScreen> createState() =>
      _ServerSupportSessionsScreenState();
}

class _ServerSupportSessionsScreenState
    extends MediaSessionState<ServerSupportSessionsScreen> {
  late final ServerAccountController _account;
  late final ServerSupportSessionsController _controller;
  late final int _accountEpoch;
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true, _expired = false, _wasCurrent = true;

  bool get _active =>
      !_expired &&
      _visible &&
      sessionCurrent(sessionGeneration) &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      widget.gateCurrent() &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _controller = ServerSupportSessionsController(_account);
    _account.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _active) _controller.load(() => mounted && _active);
    });
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountEpoch) ||
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
    if (_wasCurrent && !current) _expire();
    _wasCurrent = current;
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  @override
  void clearPendingInteraction() => _expire();

  void _expire() {
    if (!mounted || _expired) return;
    _expired = true;
    sessionGeneration++;
    void retire() {
      if (!mounted) return;
      _controller.invalidate();
      setState(() {});
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => retire());
    } else {
      retire();
    }
  }

  String _permission(AppLocalizations l10n, String permission) =>
      switch (permission) {
        supportCoreHealth => l10n.serverSupportCoreHealth,
        supportAuditVerify => l10n.serverSupportAuditVerify,
        supportResourceCount => l10n.serverSupportResourceCount,
        supportEgressSummary => l10n.serverSupportEgressSummary,
        supportActivityRead => l10n.serverSupportActivityRead,
        _ => l10n.serverSupportUnrecognized,
      };

  Future<void> _create(AppLocalizations l10n) async {
    final supporterId = TextEditingController();
    final supporterName = TextEditingController();
    var health = true;
    var audit = false;
    var resources = true;
    var egress = false;
    var activity = true;
    final result =
        await showCupertinoDialog<
          ({String id, String name, List<String> permissions})
        >(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => CupertinoAlertDialog(
              title: Text(l10n.serverSupportCreate),
              content: Column(
                children: [
                  const SizedBox(height: Gap.lg),
                  CupertinoTextField(
                    controller: supporterName,
                    maxLength: 80,
                    placeholder: l10n.serverSupportName,
                  ),
                  const SizedBox(height: Gap.md),
                  CupertinoTextField(
                    controller: supporterId,
                    maxLength: 96,
                    placeholder: l10n.serverSupportId,
                    autocorrect: false,
                  ),
                  _toggle(l10n.serverSupportCoreHealth, health, (value) {
                    setDialogState(() => health = value);
                  }),
                  _toggle(l10n.serverSupportAuditVerify, audit, (value) {
                    setDialogState(() => audit = value);
                  }),
                  _toggle(l10n.serverSupportResourceCount, resources, (value) {
                    setDialogState(() => resources = value);
                  }),
                  _toggle(l10n.serverSupportEgressSummary, egress, (value) {
                    setDialogState(() => egress = value);
                  }),
                  _toggle(l10n.serverSupportActivityRead, activity, (value) {
                    setDialogState(() => activity = value);
                  }),
                ],
              ),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n.commonCancel),
                ),
                CupertinoDialogAction(
                  isDefaultAction: true,
                  onPressed: () {
                    final id = supporterId.text.trim();
                    final name = supporterName.text.trim();
                    final permissions = [
                      if (activity) supportActivityRead,
                      if (egress) supportEgressSummary,
                      if (audit) supportAuditVerify,
                      if (health) supportCoreHealth,
                      if (resources) supportResourceCount,
                    ]..sort();
                    if (name.isNotEmpty &&
                        RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{2,95}$')
                            .hasMatch(id) &&
                        permissions.isNotEmpty) {
                      Navigator.pop(dialogContext, (
                        id: id,
                        name: name,
                        permissions: permissions,
                      ));
                    }
                  },
                  child: Text(l10n.serverSupportCreate),
                ),
              ],
            ),
          ),
        );
    supporterId.dispose();
    supporterName.dispose();
    if (result == null || !mounted || !_active) return;
    await _controller.create(
      supporterId: result.id,
      supporterName: result.name,
      permissions: result.permissions,
      current: () => mounted && _active,
    );
    final token = _controller.takeIssuedToken();
    if (token == null || !mounted || !_active) return;
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.serverSupportTokenTitle),
        content: Column(
          children: [
            const SizedBox(height: Gap.lg),
            Text(l10n.serverSupportTokenOnce),
            const SizedBox(height: Gap.md),
            Text(token),
          ],
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: token));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: Text(l10n.serverSupportCopyAndClose),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.serverSupportCloseWithoutCopy),
          ),
        ],
      ),
    );
  }

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) =>
      CupertinoListTile(
        title: Text(label),
        trailing: CupertinoSwitch(value: value, onChanged: onChanged),
      );

  Future<void> _showActivity(
    AppLocalizations l10n,
    ServerSupportSession session,
  ) async {
    await _controller.loadDetail(session, () => mounted && _active);
    final detail = _controller.detail;
    if (!mounted || !_active || detail?.session.id != session.id) return;
    await showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.serverSupportActivityTitle),
        content: SizedBox(
          height: 320,
          width: 360,
          child: detail!.activity.isEmpty
              ? Center(child: Text(l10n.serverSupportActivityEmpty))
              : ListView.separated(
                  itemCount: detail.activity.length,
                  separatorBuilder: (_, _) => const SizedBox(height: Gap.md),
                  itemBuilder: (context, index) {
                    final event = detail.activity[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_permission(l10n, event.permission)),
                        Text(
                          '${event.outcome == 'allowed' ? l10n.serverSupportAllowed : l10n.serverSupportDenied} · ${event.createdAt.toLocal()}',
                        ),
                      ],
                    );
                  },
                ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.commonClose),
          ),
        ],
      ),
    );
  }

  Future<void> _revoke(
    AppLocalizations l10n,
    ServerSupportSession session,
  ) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.serverSupportRevoke),
        content: Text(l10n.serverSupportRevokeConfirm(session.supporterName)),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.serverSupportRevoke),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted && _active) {
      await _controller.revoke(session, () => mounted && _active);
    }
  }

  String _message(AppLocalizations l10n) => switch (_controller.failure) {
    null => switch (_controller.announcement) {
      'created' => l10n.serverSupportCreated,
      'revoked' => l10n.serverSupportRevoked,
      _ => '',
    },
    'support_session_limit_reached' => l10n.serverSupportLimit,
    'support_session_changed' => l10n.serverSupportChanged,
    _ => l10n.serverSupportFailure,
  };

  Widget _session(
    AppLocalizations l10n,
    ServerSupportSession session,
    bool enabled,
  ) {
    final minutes = (session.remainingSeconds / 60).ceil();
    return SettingsSection(
      header: Text(session.supporterName),
      footer: Text(
        '${session.supporterId} · ${session.active ? l10n.serverSupportRemaining(minutes) : l10n.serverSupportInactive}',
      ),
      children: [
        CupertinoListTile(
          leading: Icon(
            session.active
                ? CupertinoIcons.lock_shield_fill
                : CupertinoIcons.lock,
          ),
          title: Text(
            session.active
                ? l10n.serverSupportActive
                : l10n.serverSupportInactive,
          ),
          subtitle: Text(
            session.permissions
                .map((value) => _permission(l10n, value))
                .join('\n'),
          ),
        ),
        CupertinoListTile(
          leading: const Icon(CupertinoIcons.eye_slash),
          title: Text(l10n.serverSupportLogPolicy),
          subtitle: Text(l10n.serverSupportLogPolicyDetail),
        ),
        SettingsActionTile(
          leading: const Icon(CupertinoIcons.doc_text_search),
          title: Text(l10n.serverSupportViewActivity),
          onTap: enabled ? () => _showActivity(l10n, session) : null,
        ),
        if (session.active)
          SettingsActionTile(
            leading: const Icon(CupertinoIcons.xmark_shield),
            title: Text(l10n.serverSupportRevoke),
            onTap: enabled ? () => _revoke(l10n, session) : null,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final enabled = _active && !_controller.busy;
        final message = _message(l10n);
        return ServiceRootScaffold(
          title: l10n.serverSupportTitle,
          trailing: CupertinoButton(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.all(12),
            onPressed: enabled ? () => _create(l10n) : null,
            child: const Icon(CupertinoIcons.add),
          ),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  Gap.xl,
                  Gap.lg,
                  Gap.xl,
                  0,
                ),
                child: Text(l10n.serverSupportIntro),
              ),
            ),
            if (_controller.busy)
              const SliverFilledMessage(
                child: CupertinoActivityIndicator(radius: 14),
              )
            else if (_controller.sessions.isEmpty)
              SliverFilledMessage(child: Text(l10n.serverSupportEmpty))
            else
              for (final session in _controller.sessions)
                SliverToBoxAdapter(child: _session(l10n, session, enabled)),
            if (message.isNotEmpty || _controller.needsRefresh)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Semantics(liveRegion: true, child: Text(message)),
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _controller.dispose();
    super.dispose();
  }
}
