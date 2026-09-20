import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_tablet_fleet_controller.dart';
import '../domain/server_tablet_fleet_models.dart';

class ServerTabletFleetScreen extends ConsumerStatefulWidget {
  const ServerTabletFleetScreen({super.key});

  @override
  ConsumerState<ServerTabletFleetScreen> createState() =>
      _ServerTabletFleetScreenState();
}

class _ServerTabletFleetScreenState
    extends MediaSessionState<ServerTabletFleetScreen> {
  late final ServerAccountController _account;
  late final ServerTabletFleetController _fleet;
  late final int _accountEpoch;
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true, _expired = false, _loaded = false, _wasCurrent = true;
  Route<bool>? _dialog;

  bool get _active =>
      !_expired &&
      _visible &&
      sessionCurrent(sessionGeneration) &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      (ModalRoute.of(context)?.isCurrent == true || _dialog?.isCurrent == true);

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _fleet = ServerTabletFleetController(_account);
    _account.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
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
    if (!mounted || _expired) return;
    _expired = true;
    sessionGeneration++;
    final route = _dialog;
    _dialog = null;
    void retire() {
      if (!mounted) return;
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
      _fleet.invalidate();
      setState(() {});
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => retire());
    } else {
      retire();
    }
  }

  Future<void> _load() async {
    if (!mounted || !_active) return;
    await _fleet.load(current: () => mounted && _active);
    if (mounted && _active) setState(() => _loaded = true);
  }

  Future<void> _confirmRevoke(ManagedTablet tablet) async {
    if (!_active || _fleet.busy || tablet.state == TabletFleetState.revoked) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final route = CupertinoDialogRoute<bool>(
      context: context,
      builder: (_) => CupertinoAlertDialog(
        title: Text(l10n.serverTabletFleetRevokeTitle),
        content: Text(l10n.serverTabletFleetRevokeHint(tablet.name)),
        actions: [
          CupertinoDialogAction(
            key: const ValueKey('tablet-revoke-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('tablet-revoke-confirm'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.serverTabletFleetRevoke),
          ),
        ],
      ),
    );
    _dialog = route;
    final accepted = await Navigator.of(context).push(route);
    if (identical(_dialog, route)) _dialog = null;
    if (accepted == true && mounted && _active) {
      await _fleet.revoke(tablet, current: () => mounted && _active);
    }
  }

  String _message(AppLocalizations l10n) {
    if (_fleet.needsRefresh) return l10n.serverTabletFleetUncertain;
    return switch (_fleet.failure) {
      null => switch (_fleet.announcement) {
        'profile_updated' => l10n.serverTabletFleetProfileVerified,
        'tablet_revoked' => l10n.serverTabletFleetRevokedVerified,
        'command_verified' => l10n.serverTabletFleetCommandVerified,
        _ => '',
      },
      'tablet_device_changed' ||
      'tablet_profile_changed' => l10n.serverTabletFleetConflict,
      'tablet_capability_unavailable' =>
        l10n.serverTabletFleetCapabilityUnavailable,
      'unauthorized' || 'forbidden' => l10n.serverServicesUnauthorized,
      _ => l10n.serverTabletFleetFailure,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _fleet,
      builder: (context, _) {
        final message = _message(l10n);
        final canAct = _active && !_fleet.busy && !_fleet.needsRefresh;
        return ServiceRootScaffold(
          title: l10n.serverTabletFleetTitle,
          trailing: CupertinoButton(
            key: const ValueKey('tablet-fleet-refresh'),
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.all(12),
            onPressed: canAct ? _load : null,
            child: Semantics(
              label: l10n.commonRefresh,
              button: true,
              excludeSemantics: true,
              child: const Icon(CupertinoIcons.refresh),
            ),
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
                child: Text(l10n.serverTabletFleetIntro),
              ),
            ),
            if (_fleet.busy && !_loaded)
              const SliverFilledMessage(
                child: CupertinoActivityIndicator(radius: 14),
              )
            else if (_loaded && _fleet.tablets.isEmpty)
              SliverFilledMessage(child: Text(l10n.serverTabletFleetEmpty))
            else
              SliverToBoxAdapter(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 1000;
                    final width = wide
                        ? (constraints.maxWidth - Gap.xl * 3) / 2
                        : constraints.maxWidth;
                    return Wrap(
                      alignment: WrapAlignment.center,
                      runAlignment: WrapAlignment.start,
                      children: [
                        for (final tablet in _fleet.tablets)
                          SizedBox(
                            width: width,
                            child: _tabletSection(
                              context,
                              tablet,
                              enabled: canAct,
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            if (message.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Semantics(
                    key: const ValueKey('tablet-fleet-live-status'),
                    liveRegion: true,
                    child: Text(message),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _tabletSection(
    BuildContext context,
    ManagedTablet tablet, {
    required bool enabled,
  }) {
    final l10n = AppLocalizations.of(context);
    final active = tablet.state == TabletFleetState.active;
    final owner = tablet.mode == TabletManagementMode.deviceOwner;
    final receipt = _fleet.latestCommands[tablet.id];
    return SettingsSection(
      key: ValueKey('tablet-card-${tablet.id}'),
      header: Text(tablet.name),
      footer: Text(
        owner
            ? l10n.serverTabletFleetOwnerProof
            : l10n.serverTabletFleetStandardProof,
      ),
      children: [
        CupertinoListTile(
          leading: Icon(
            owner
                ? CupertinoIcons.lock_shield_fill
                : CupertinoIcons.device_phone_portrait,
          ),
          title: Text(
            owner
                ? l10n.serverTabletFleetDeviceOwner
                : l10n.serverTabletFleetStandard,
          ),
          subtitle: Text(
            active
                ? l10n.serverTabletFleetActive
                : l10n.serverTabletFleetRevoked,
          ),
          additionalInfo: Text('v${tablet.clientVersion}'),
        ),
        CupertinoListTile(
          title: Text(l10n.serverTabletFleetProfile),
          subtitle: Text(
            l10n.serverTabletFleetProfileRevisions(
              tablet.appliedProfileRevision,
              tablet.desiredProfileRevision,
            ),
          ),
          additionalInfo: Text(
            tablet.profileState == TabletProfileState.current
                ? l10n.serverTabletFleetProfileCurrent
                : l10n.serverTabletFleetProfilePending,
          ),
        ),
        SettingsActionTile(
          buttonKey: ValueKey('tablet-profile-${tablet.id}'),
          leading: const Icon(CupertinoIcons.slider_horizontal_3),
          title: Text(l10n.serverTabletFleetAdvanceProfile),
          onTap: enabled && active
              ? () => _fleet.advanceProfile(
                  tablet,
                  current: () => mounted && _active,
                )
              : null,
        ),
        SettingsActionTile(
          buttonKey: ValueKey('tablet-refresh-${tablet.id}'),
          leading: const Icon(CupertinoIcons.refresh_circled),
          title: Text(l10n.serverTabletFleetRefreshDashboard),
          additionalInfo: receipt?.kind == TabletCommandKind.refreshDashboard
              ? Text(l10n.serverTabletFleetReceipt(receipt!.state.name))
              : null,
          onTap: enabled && active
              ? () => _fleet.issue(
                  tablet,
                  TabletCommandKind.refreshDashboard,
                  current: () => mounted && _active,
                )
              : null,
        ),
        if (owner) ...[
          SettingsActionTile(
            buttonKey: ValueKey('tablet-restart-${tablet.id}'),
            leading: const Icon(CupertinoIcons.restart),
            title: Text(l10n.serverTabletFleetRestartClient),
            onTap: enabled && active
                ? () => _fleet.issue(
                    tablet,
                    TabletCommandKind.restartClient,
                    current: () => mounted && _active,
                  )
                : null,
          ),
          SettingsActionTile(
            buttonKey: ValueKey('tablet-lock-${tablet.id}'),
            leading: const Icon(CupertinoIcons.lock),
            title: Text(l10n.serverTabletFleetLockKiosk),
            onTap: enabled && active
                ? () => _fleet.issue(
                    tablet,
                    TabletCommandKind.lockKiosk,
                    current: () => mounted && _active,
                  )
                : null,
          ),
        ],
        SettingsActionTile(
          buttonKey: ValueKey('tablet-revoke-${tablet.id}'),
          leading: const Icon(CupertinoIcons.xmark_circle),
          title: Text(l10n.serverTabletFleetRevoke),
          onTap: enabled && active ? () => _confirmRevoke(tablet) : null,
        ),
      ],
    );
  }

  @override
  void dispose() {
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _fleet.dispose();
    super.dispose();
  }
}
