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
import '../data/server_mcp_gateway_controller.dart';
import '../domain/server_mcp_gateway_models.dart';

class ServerMcpGatewayScreen extends ConsumerStatefulWidget {
  const ServerMcpGatewayScreen({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;

  @override
  ConsumerState<ServerMcpGatewayScreen> createState() =>
      _ServerMcpGatewayScreenState();
}

class _ServerMcpGatewayScreenState
    extends MediaSessionState<ServerMcpGatewayScreen> {
  late final ServerAccountController _account;
  late final ServerMcpGatewayController _controller;
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
    _controller = ServerMcpGatewayController(_account);
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

  Future<void> _create(AppLocalizations l10n) async {
    final clientId = TextEditingController();
    final clientName = TextEditingController();
    var allowRead = true;
    var allowWrite = false;
    final result =
        await showCupertinoDialog<
          ({String clientId, String clientName, List<String> tools})
        >(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => CupertinoAlertDialog(
              title: Text(l10n.serverMcpCreate),
              content: Column(
                children: [
                  const SizedBox(height: Gap.lg),
                  CupertinoTextField(
                    controller: clientName,
                    maxLength: 80,
                    placeholder: l10n.serverMcpClientName,
                  ),
                  const SizedBox(height: Gap.md),
                  CupertinoTextField(
                    controller: clientId,
                    maxLength: 96,
                    placeholder: l10n.serverMcpClientId,
                    autocorrect: false,
                  ),
                  CupertinoListTile(
                    title: Text(l10n.serverMcpReadTool),
                    trailing: CupertinoSwitch(
                      value: allowRead,
                      onChanged: (value) =>
                          setDialogState(() => allowRead = value),
                    ),
                  ),
                  CupertinoListTile(
                    title: Text(l10n.serverMcpWriteTool),
                    subtitle: Text(l10n.serverMcpWriteHint),
                    trailing: CupertinoSwitch(
                      value: allowWrite,
                      onChanged: (value) =>
                          setDialogState(() => allowWrite = value),
                    ),
                  ),
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
                    final id = clientId.text.trim();
                    final name = clientName.text.trim();
                    final tools = [
                      if (allowWrite) serverMcpWriteTool,
                      if (allowRead) serverMcpReadTool,
                    ]..sort();
                    if (name.isNotEmpty &&
                        RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{2,95}$')
                            .hasMatch(id) &&
                        tools.isNotEmpty) {
                      Navigator.pop(dialogContext, (
                        clientId: id,
                        clientName: name,
                        tools: tools,
                      ));
                    }
                  },
                  child: Text(l10n.serverMcpCreate),
                ),
              ],
            ),
          ),
        );
    clientId.dispose();
    clientName.dispose();
    if (result == null || !mounted || !_active) return;
    await _controller.create(
      clientId: result.clientId,
      clientName: result.clientName,
      tools: result.tools,
      current: () => mounted && _active,
    );
    final token = _controller.takeIssuedToken();
    if (token == null || !mounted || !_active) return;
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.serverMcpTokenTitle),
        content: Column(
          children: [
            const SizedBox(height: Gap.lg),
            Text(l10n.serverMcpTokenOnce),
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
            child: Text(l10n.serverMcpCopyAndClose),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.serverMcpCloseWithoutCopy),
          ),
        ],
      ),
    );
  }

  String _message(AppLocalizations l10n) => switch (_controller.failure) {
    null => switch (_controller.announcement) {
      'created' => l10n.serverMcpCreated,
      'revoked' => l10n.serverMcpRevoked,
      _ => '',
    },
    'mcp_grant_limit_reached' => l10n.serverMcpLimit,
    'mcp_grant_changed' => l10n.serverMcpChanged,
    _ => l10n.serverMcpFailure,
  };

  Widget _grant(
    AppLocalizations l10n,
    ServerMcpGrant grant,
    bool enabled,
  ) => SettingsSection(
    header: Text(grant.clientName),
    footer: Text(
      '${grant.clientId} · ${l10n.serverMcpExpires(grant.expiresAt.toLocal().toString())}',
    ),
    children: [
      CupertinoListTile(
        leading: Icon(
          grant.active ? CupertinoIcons.lock_shield_fill : CupertinoIcons.lock,
        ),
        title: Text(
          grant.active ? l10n.serverMcpActive : l10n.serverMcpInactive,
        ),
        subtitle: Text(grant.tools.join('\n')),
      ),
      if (grant.active)
        SettingsActionTile(
          leading: const Icon(CupertinoIcons.xmark_shield),
          title: Text(l10n.serverMcpRevoke),
          onTap: enabled
              ? () => _controller.revoke(grant, () => mounted && _active)
              : null,
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final enabled = _active && !_controller.busy;
        final message = _message(l10n);
        return ServiceRootScaffold(
          title: l10n.serverMcpTitle,
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
                child: Text(l10n.serverMcpIntro),
              ),
            ),
            if (_controller.busy)
              const SliverFilledMessage(
                child: CupertinoActivityIndicator(radius: 14),
              )
            else if (_controller.grants.isEmpty)
              SliverFilledMessage(child: Text(l10n.serverMcpEmpty))
            else
              for (final grant in _controller.grants.reversed)
                SliverToBoxAdapter(child: _grant(l10n, grant, enabled)),
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
