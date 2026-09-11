import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/home_session_controller.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/connection_evidence_status.dart';
import '../../../../shared/widgets/core_infrastructure_evidence.dart';
import '../../../keenetic/core/data/core_keenetic_dashboard_providers.dart';
import '../../../keenetic/core/data/core_keenetic_providers.dart';
import '../../../keenetic/core/domain/core_keenetic_models.dart';
import '../../../keenetic/core/presentation/core_keenetic_screen.dart';
import '../../../keenetic/core_command/core_keenetic_command.dart';
import '../../../home_resources/domain/home_resource_models.dart';
import '../../../server/domain/server_models.dart';
import '../../../settings/presentation/settings_file_dialog.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../domain/tile_config.dart';

String _rate(int? value, AppLocalizations l) {
  if (value == null) return l.commonUnknown;
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)} MB/s';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)} KB/s';
  return '$value B/s';
}

String _uptime(int seconds, AppLocalizations l) {
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  return days > 0
      ? '$days${l.keeneticUptimeDays} $hours${l.keeneticUptimeHours}'
      : '$hours${l.keeneticUptimeHours}';
}

String _bytes(int value) {
  if (value >= 1099511627776) {
    return '${(value / 1099511627776).toStringAsFixed(1)} TB';
  }
  if (value >= 1073741824) {
    return '${(value / 1073741824).toStringAsFixed(1)} GB';
  }
  if (value >= 1048576) return '${(value / 1048576).toStringAsFixed(1)} MB';
  if (value >= 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  return '$value B';
}

String _percent(double? value, AppLocalizations l) =>
    value == null ? l.commonUnknown : '${value.toStringAsFixed(0)}%';

String _failure(String code, AppLocalizations l) => switch (code) {
  'not_found' => l.coreKeeneticNoBinding,
  'forbidden' || 'unauthorized' => l.coreKeeneticPermission,
  'keenetic_upstream_denied' => l.coreKeeneticDenied,
  'keenetic_snapshot_unsupported' ||
  'invalid_response' => l.coreKeeneticUnsupported,
  'resource_changed' || 'conflict' => l.coreKeeneticChanged,
  'core_required' || 'cancelled' => l.coreKeeneticRequired,
  _ => l.coreKeeneticOffline,
};

bool coreKeeneticCommandEntryAllowed({
  required ServerSession? session,
  required HomeResourceRecord target,
  required CoreKeeneticSnapshot? snapshot,
  required bool pinConfigured,
}) =>
    session?.context == target.context &&
    session!.user.canAdminister &&
    pinConfigured &&
    snapshot != null &&
    snapshot.remainingTtlMs > 0 &&
    snapshot.resourceRevision == target.revision &&
    snapshot.aclRevision == target.aclRevision &&
    snapshot.telemetry.status.firmware != null &&
    snapshot.telemetry.status.firmwareRevision != null &&
    snapshot.telemetry.status.statusRevision != null;

class CoreKeeneticDashboardCard extends StatelessWidget {
  const CoreKeeneticDashboardCard({
    super.key,
    required this.title,
    required this.snapshot,
    required this.failure,
    required this.stale,
    required this.loading,
    required this.onPressed,
    required this.onRefresh,
    required this.onCommands,
  });
  final String title;
  final CoreKeeneticSnapshot? snapshot;
  final String? failure;
  final bool stale, loading;
  final VoidCallback? onPressed;
  final VoidCallback? onRefresh, onCommands;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), value = snapshot?.telemetry;
    final evidence = coreInfrastructureEvidence(
      busy: loading,
      stale: stale,
      failure: failure,
      verifiedAt: snapshot?.observedAt,
    );
    final state = loading
        ? l.commonLoading
        : stale
        ? l.coreKeeneticStale
        : failure != null
        ? _failure(failure!, l)
        : value == null
        ? l.commonUnknown
        : value.status.online
        ? l.keeneticOnline
        : l.keeneticOffline;
    final guest = value?.guestInterfaces;
    final metrics = value == null
        ? <(String, String)>[]
        : [
            (l.coreKeeneticPublicIp, value.status.publicIp ?? l.commonUnknown),
            (
              '${l.keeneticDownloadRate} / ${l.keeneticUploadRate}',
              '${_rate(value.traffic.downloadBps, l)} / ${_rate(value.traffic.uploadBps, l)}',
            ),
            (
              l.coreKeeneticTrafficTotal,
              '${_bytes(value.traffic.rxBytes)} ↓ / ${_bytes(value.traffic.txBytes)} ↑',
            ),
            (l.keeneticUptime, _uptime(value.status.uptimeSeconds, l)),
            (l.keeneticFirmware, value.status.firmware ?? l.commonUnknown),
            (
              l.coreKeeneticGuestWifi,
              guest!.isEmpty
                  ? l.coreKeeneticGuestUnavailable
                  : guest.any((item) => item.online)
                  ? l.coreKeeneticGuestEnabled
                  : l.coreKeeneticGuestDisabled,
            ),
            (
              '${l.keeneticCpuUsage} / ${l.keeneticMemoryUsage}',
              '${_percent(value.status.cpuPercent, l)} / '
                  '${_percent(value.status.memoryPercent, l)}',
            ),
            (l.keeneticConnectedDevices, '${value.onlineHosts}'),
          ];
    final evidenceLabels = connectionEvidenceLabels(
      l,
      evidence,
      showTimestamp: false,
    );
    final semantics =
        '$title. ${evidenceLabels.join('. ')}. $state. '
        '${metrics.map((item) => '${item.$1}, ${item.$2}').join('. ')}';
    return Semantics(
      key: const ValueKey('core-keenetic-dashboard-card'),
      label: semantics,
      container: true,
      child: Container(
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: Icon(
                    value?.status.online == true
                        ? CupertinoIcons.wifi
                        : CupertinoIcons.wifi_slash,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tileTitle.copyWith(
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ConnectionEvidenceStatus(
              evidence: evidence,
              compact: true,
              showTimestamp: false,
            ),
            const SizedBox(height: 6),
            Text(
              state,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.footnote.copyWith(
                color: stale || failure != null || value?.status.online == false
                    ? CupertinoColors.systemOrange.resolveFrom(context)
                    : CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            if (metrics.isNotEmpty)
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 860 ? 4 : 2;
                    final rows = (metrics.length / columns).ceil();
                    final ratio =
                        (constraints.maxWidth / columns) /
                        (constraints.maxHeight / rows);
                    return GridView.count(
                      physics: const NeverScrollableScrollPhysics(),
                      padding: EdgeInsets.zero,
                      crossAxisCount: columns,
                      childAspectRatio: ratio,
                      children: [
                        for (final item in metrics) _Metric(item: item),
                      ],
                    );
                  },
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: _CardAction(
                    actionKey: const ValueKey('core-keenetic-open-card'),
                    label: l.coreKeeneticViewDetails,
                    icon: CupertinoIcons.chart_bar,
                    onPressed: onPressed,
                  ),
                ),
                _CardAction(
                  actionKey: const ValueKey('core-keenetic-refresh-card'),
                  label: l.commonRefresh,
                  icon: CupertinoIcons.refresh,
                  onPressed: onRefresh,
                  iconOnly: true,
                ),
                if (onCommands != null)
                  Expanded(
                    child: _CardAction(
                      actionKey: const ValueKey('core-keenetic-commands'),
                      label: l.coreKeeneticControls,
                      icon: CupertinoIcons.lock_shield,
                      onPressed: onCommands,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.item});
  final (String, String) item;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '${item.$1}, ${item.$2}',
    child: Padding(
      padding: const EdgeInsetsDirectional.only(end: 10, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            item.$1,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.footnote.copyWith(
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          Text(
            item.$2,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.body.copyWith(
              color: CupertinoColors.label.resolveFrom(context),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.actionKey,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.iconOnly = false,
  });
  final Key actionKey;
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool iconOnly;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: CupertinoButton(
      key: actionKey,
      minimumSize: const Size.square(48),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          if (!iconOnly) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ],
      ),
    ),
  );
}

class CoreKeeneticTile extends ConsumerStatefulWidget {
  const CoreKeeneticTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  ConsumerState<CoreKeeneticTile> createState() => _CoreKeeneticTileState();
}

class _CoreKeeneticTileState extends ConsumerState<CoreKeeneticTile> {
  late final AppLifecycleListener _lifecycle;
  bool _foreground = true, _stale = false;
  Timer? _expiry;
  CoreKeeneticSnapshot? _armed;
  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (!mounted) return;
        final next = state == AppLifecycleState.resumed;
        if (!next) _expiry?.cancel();
        setState(() => _foreground = next);
      },
    );
  }

  void _arm(CoreKeeneticSnapshot value) {
    if (identical(_armed, value)) return;
    _armed = value;
    _stale = false;
    _expiry?.cancel();
    _expiry = Timer(Duration(milliseconds: value.remainingTtlMs), () {
      if (mounted) setState(() => _stale = true);
    });
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  bool _commandEntryAllowed(
    ServerSession? session,
    HomeResourceRecord target,
    CoreKeeneticSnapshot? snapshot,
    bool pinConfigured,
  ) =>
      !_stale &&
      coreKeeneticCommandEntryAllowed(
        session: session,
        target: target,
        snapshot: snapshot,
        pinConfigured: pinConfigured,
      );

  Future<void> _openCommands(
    ServerSession session,
    HomeResourceRecord target,
    CoreKeeneticSnapshot snapshot,
  ) async {
    final home = ref.read(homeSessionControllerProvider);
    final identity = home?.runtimeIdentity;
    final pin = ref.read(pinLockProvider);
    if (!_commandEntryAllowed(session, target, snapshot, pin.value != null)) {
      return;
    }
    final accepted = await reauthenticateSettingsFileDialog(
      context,
      ref.read(pinLockStoreProvider),
    );
    if (!mounted || !accepted) return;
    final currentHome = ref.read(homeSessionControllerProvider);
    final currentPin = ref.read(pinLockProvider);
    final currentSession = currentHome?.account.session;
    if (!identical(home, currentHome) ||
        currentHome?.runtimeIdentity != identity ||
        !identical(session, currentSession) ||
        !_commandEntryAllowed(
          currentSession,
          target,
          snapshot,
          currentPin.value != null,
        )) {
      return;
    }
    final transport = ref.read(coreKeeneticApiFactoryProvider)(
      session.endpoint,
    );
    bool current() {
      final latestHome = ref.read(homeSessionControllerProvider);
      final latestPin = ref.read(pinLockProvider);
      return mounted &&
          !_stale &&
          identical(_armed, snapshot) &&
          identical(home, latestHome) &&
          latestHome?.runtimeIdentity == identity &&
          identical(session, latestHome?.account.session) &&
          _commandEntryAllowed(
            latestHome?.account.session,
            target,
            snapshot,
            latestPin.value != null,
          );
    }

    if (!current()) {
      transport.close();
      return;
    }
    await Navigator.of(context).push<void>(
      CupertinoPageRoute(
        builder: (_) => CoreKeeneticCommandAuthorityScreen(
          authority: HttpCoreKeeneticCommandAuthority(
            server: transport,
            accessToken: session.accessToken,
            coreId: target.context.coreId,
            homeId: target.context.homeId,
            resourceId: target.id,
          ),
          isCurrent: current,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _foreground && TickerMode.valuesOf(context).enabled;
    final reading = active
        ? ref.watch(coreKeeneticDashboardSnapshotProvider(widget.tile))
        : null;
    final value = reading?.value;
    if (value != null) _arm(value);
    final error = reading?.error;
    final failure = error is LarenorServerException
        ? error.code
        : reading?.hasError == true
        ? 'connection_failed'
        : null;
    ServerSession? session;
    HomeResourceRecord? target;
    try {
      session = ref.watch(homeSessionControllerProvider)?.account.session;
      if (session?.context != null) {
        target = coreKeeneticTileTarget(widget.tile, session!.context!);
      }
    } catch (_) {
      session = null;
      target = null;
    }
    final pin = ref.watch(pinLockProvider);
    final canCommand =
        active &&
        target != null &&
        _commandEntryAllowed(session, target, value, pin.value != null);
    return CoreKeeneticDashboardCard(
      title: widget.tile.title ?? 'Keenetic',
      snapshot: _stale ? null : value,
      failure: failure,
      stale: _stale,
      loading: reading?.isLoading == true,
      onPressed: !active || value == null || _stale
          ? null
          : () {
              try {
                final session = ref
                    .read(homeSessionControllerProvider)
                    ?.account
                    .session;
                if (session?.context == null) return;
                final target = coreKeeneticTileTarget(
                  widget.tile,
                  session!.context!,
                );
                Navigator.of(context).push<void>(
                  CupertinoPageRoute(
                    builder: (_) =>
                        CoreKeeneticScreen(target: target, admin: false),
                  ),
                );
              } catch (_) {
                return;
              }
            },
      onRefresh: !active
          ? null
          : () => ref.invalidate(
              coreKeeneticDashboardSnapshotProvider(widget.tile),
            ),
      onCommands: canCommand
          ? () => unawaited(_openCommands(session!, target!, value!))
          : null,
    );
  }
}

class _CoreKeeneticReadOnlyCard extends StatelessWidget {
  const _CoreKeeneticReadOnlyCard({
    required this.cardKey,
    required this.refreshKey,
    required this.title,
    required this.icon,
    required this.state,
    required this.alert,
    required this.loading,
    required this.children,
    required this.onRefresh,
  });
  final Key cardKey, refreshKey;
  final String title, state;
  final IconData icon;
  final bool alert, loading;
  final List<Widget> children;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => Semantics(
    key: cardKey,
    container: true,
    readOnly: true,
    label: '$title. $state',
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ExcludeSemantics(child: Icon(icon, size: 20)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tileTitle,
                  ),
                ),
                Semantics(
                  button: true,
                  label: AppLocalizations.of(context).commonRefresh,
                  child: CupertinoButton(
                    key: refreshKey,
                    minimumSize: const Size.square(48),
                    padding: const EdgeInsets.all(8),
                    onPressed: onRefresh,
                    child: loading
                        ? const CupertinoActivityIndicator()
                        : const Icon(CupertinoIcons.refresh, size: 20),
                  ),
                ),
              ],
            ),
            Text(
              state,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.footnote.copyWith(
                color: alert
                    ? CupertinoColors.systemOrange.resolveFrom(context)
                    : CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: ListView(
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.zero,
                children: children,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class CoreKeeneticDetailsDashboardCard extends StatelessWidget {
  const CoreKeeneticDetailsDashboardCard({
    super.key,
    required this.title,
    required this.page,
    required this.failure,
    required this.stale,
    required this.loading,
    required this.onRefresh,
  });
  final String title;
  final CoreKeeneticDetailsPage? page;
  final String? failure;
  final bool stale, loading;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final state = loading
        ? l.commonLoading
        : stale
        ? l.coreKeeneticStale
        : failure != null
        ? _failure(failure!, l)
        : page == null
        ? l.commonUnknown
        : '${page!.clients.length} ${l.coreKeeneticDetailsClients.toLowerCase()}, '
              '${page!.interfaces.length} ${l.coreKeeneticDetailsInterfaces.toLowerCase()}';
    return _CoreKeeneticReadOnlyCard(
      cardKey: const ValueKey('core-keenetic-details-card'),
      refreshKey: const ValueKey('core-keenetic-details-refresh'),
      title: title,
      icon: CupertinoIcons.list_bullet,
      state: state,
      alert: stale || failure != null,
      loading: loading,
      onRefresh: onRefresh,
      children: [
        for (final item in page?.entries.take(4) ?? <CoreKeeneticDetail>[])
          Semantics(
            readOnly: true,
            label:
                '${item.name}, ${item.online ? l.keeneticOnline : l.keeneticOffline}',
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      item.online
                          ? CupertinoIcons.circle_fill
                          : CupertinoIcons.circle,
                      size: 10,
                      color: item.online
                          ? CupertinoColors.systemGreen.resolveFrom(context)
                          : CupertinoColors.systemGrey.resolveFrom(context),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class CoreKeeneticTopologyDashboardCard extends StatelessWidget {
  const CoreKeeneticTopologyDashboardCard({
    super.key,
    required this.title,
    required this.topology,
    required this.failure,
    required this.stale,
    required this.loading,
    required this.onRefresh,
  });
  final String title;
  final CoreKeeneticTopologySnapshot? topology;
  final String? failure;
  final bool stale, loading;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final nodes = topology?.nodes ?? const <CoreKeeneticMeshNode>[];
    final state = loading
        ? l.commonLoading
        : stale
        ? l.coreKeeneticStale
        : failure != null
        ? _failure(failure!, l)
        : topology == null
        ? l.commonUnknown
        : '${nodes.where((node) => node.online).length}/${nodes.length} '
              '${l.coreKeeneticMeshNodes.toLowerCase()}';
    return _CoreKeeneticReadOnlyCard(
      cardKey: const ValueKey('core-keenetic-mesh-card'),
      refreshKey: const ValueKey('core-keenetic-mesh-refresh'),
      title: title,
      icon: CupertinoIcons.dot_radiowaves_left_right,
      state: state,
      alert: stale || failure != null,
      loading: loading,
      onRefresh: onRefresh,
      children: [
        for (final node in nodes.take(4))
          Semantics(
            readOnly: true,
            label:
                '${node.name}, ${node.online ? l.keeneticOnline : l.keeneticOffline}',
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      node.role == CoreKeeneticMeshRole.controller
                          ? CupertinoIcons.wifi
                          : CupertinoIcons.antenna_radiowaves_left_right,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        node.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (node.quality != null)
                      Text(
                        node.quality!.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.footnote,
                      ),
                  ],
                ),
              ),
            ),
          ),
        if (topology != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${topology!.networks.length} ${l.coreKeeneticMeshNetworks.toLowerCase()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.footnote,
            ),
          ),
      ],
    );
  }
}

/// A privacy-first client summary. Network identifiers remain available only
/// in the explicit details screen and are never rendered on a shared dashboard.
class CoreKeeneticClientsDashboardCard extends StatelessWidget {
  const CoreKeeneticClientsDashboardCard({
    super.key,
    required this.title,
    required this.page,
    required this.failure,
    required this.stale,
    required this.loading,
    required this.onRefresh,
  });
  final String title;
  final CoreKeeneticDetailsPage? page;
  final String? failure;
  final bool stale, loading;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final clients = page?.clients ?? const <CoreKeeneticClientDetail>[];
    final state = loading
        ? l.commonLoading
        : stale
        ? l.coreKeeneticStale
        : failure != null
        ? _failure(failure!, l)
        : page == null
        ? l.commonUnknown
        : '${clients.where((item) => item.online).length}/${clients.length} '
              '${l.keeneticConnectedDevices.toLowerCase()}';
    return _CoreKeeneticReadOnlyCard(
      cardKey: const ValueKey('core-keenetic-clients-card'),
      refreshKey: const ValueKey('core-keenetic-clients-refresh'),
      title: title,
      icon: CupertinoIcons.device_laptop,
      state: state,
      alert: stale || failure != null,
      loading: loading,
      onRefresh: onRefresh,
      children: [
        for (final client in clients.take(6))
          Semantics(
            readOnly: true,
            label:
                '${client.name}, ${client.online ? l.keeneticOnline : l.keeneticOffline}, '
                '${client.band ?? l.commonUnknown}, '
                '${client.signalDbm ?? l.commonUnknown}',
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      client.online
                          ? CupertinoIcons.circle_fill
                          : CupertinoIcons.circle,
                      size: 10,
                      color: client.online
                          ? CupertinoColors.systemGreen.resolveFrom(context)
                          : CupertinoColors.systemGrey.resolveFrom(context),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        client.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (client.band != null)
                      Text('${client.band} GHz', style: AppText.footnote),
                    if (client.signalDbm != null) ...[
                      const SizedBox(width: 8),
                      Text('${client.signalDbm} dBm', style: AppText.footnote),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class CoreKeeneticBandwidthDashboardCard extends StatelessWidget {
  const CoreKeeneticBandwidthDashboardCard({
    super.key,
    required this.title,
    required this.snapshot,
    required this.failure,
    required this.stale,
    required this.loading,
    required this.onRefresh,
  });
  final String title;
  final CoreKeeneticSnapshot? snapshot;
  final String? failure;
  final bool stale, loading;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context),
        traffic = snapshot?.telemetry.traffic;
    final state = loading
        ? l.commonLoading
        : stale
        ? l.coreKeeneticStale
        : failure != null
        ? _failure(failure!, l)
        : traffic == null
        ? l.commonUnknown
        : snapshot!.telemetry.status.online
        ? l.keeneticOnline
        : l.keeneticOffline;
    return _CoreKeeneticReadOnlyCard(
      cardKey: const ValueKey('core-keenetic-bandwidth-card'),
      refreshKey: const ValueKey('core-keenetic-bandwidth-refresh'),
      title: title,
      icon: CupertinoIcons.speedometer,
      state: state,
      alert:
          stale ||
          failure != null ||
          snapshot?.telemetry.status.online == false,
      loading: loading,
      onRefresh: onRefresh,
      children: traffic == null
          ? const []
          : [
              _Metric(
                item: (l.keeneticDownloadRate, _rate(traffic.downloadBps, l)),
              ),
              _Metric(
                item: (l.keeneticUploadRate, _rate(traffic.uploadBps, l)),
              ),
              _Metric(
                item: (
                  l.coreKeeneticTrafficTotal,
                  '${_bytes(traffic.rxBytes)} ↓ / ${_bytes(traffic.txBytes)} ↑',
                ),
              ),
            ],
    );
  }
}

mixin _CoreKeeneticReadonlyTileLifecycle<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  late final AppLifecycleListener keeneticLifecycle;
  bool keeneticForeground = true, keeneticStale = false;
  Timer? keeneticExpiry;
  Object? keeneticArmed;

  void initKeeneticLifecycle() {
    final state = WidgetsBinding.instance.lifecycleState;
    keeneticForeground = state == null || state == AppLifecycleState.resumed;
    keeneticLifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (!mounted) return;
        final next = state == AppLifecycleState.resumed;
        if (!next) keeneticExpiry?.cancel();
        setState(() => keeneticForeground = next);
      },
    );
  }

  void armKeenetic(Object value, int ttlMs) {
    if (identical(keeneticArmed, value)) return;
    keeneticArmed = value;
    keeneticStale = false;
    keeneticExpiry?.cancel();
    keeneticExpiry = Timer(Duration(milliseconds: ttlMs), () {
      if (mounted) setState(() => keeneticStale = true);
    });
  }

  void disposeKeeneticLifecycle() {
    keeneticExpiry?.cancel();
    keeneticLifecycle.dispose();
  }
}

class CoreKeeneticDetailsTile extends ConsumerStatefulWidget {
  const CoreKeeneticDetailsTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  ConsumerState<CoreKeeneticDetailsTile> createState() =>
      _CoreKeeneticDetailsTileState();
}

class _CoreKeeneticDetailsTileState
    extends ConsumerState<CoreKeeneticDetailsTile>
    with _CoreKeeneticReadonlyTileLifecycle<CoreKeeneticDetailsTile> {
  @override
  void initState() {
    super.initState();
    initKeeneticLifecycle();
  }

  @override
  void dispose() {
    disposeKeeneticLifecycle();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = keeneticForeground && TickerMode.valuesOf(context).enabled;
    final reading = active
        ? ref.watch(coreKeeneticDashboardDetailsProvider(widget.tile))
        : null;
    final value = reading?.value;
    if (value != null) {
      armKeenetic(value, value.authority.remainingTtlMs);
    }
    final error = reading?.error;
    final failure = error is LarenorServerException
        ? error.code
        : reading?.hasError == true
        ? 'connection_failed'
        : null;
    return CoreKeeneticDetailsDashboardCard(
      title: widget.tile.title ?? 'Keenetic',
      page: keeneticStale ? null : value?.page,
      failure: failure,
      stale: keeneticStale,
      loading: reading?.isLoading == true,
      onRefresh: active
          ? () => ref.invalidate(
              coreKeeneticDashboardDetailsProvider(widget.tile),
            )
          : null,
    );
  }
}

class CoreKeeneticMeshTile extends ConsumerStatefulWidget {
  const CoreKeeneticMeshTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  ConsumerState<CoreKeeneticMeshTile> createState() =>
      _CoreKeeneticMeshTileState();
}

class _CoreKeeneticMeshTileState extends ConsumerState<CoreKeeneticMeshTile>
    with _CoreKeeneticReadonlyTileLifecycle<CoreKeeneticMeshTile> {
  @override
  void initState() {
    super.initState();
    initKeeneticLifecycle();
  }

  @override
  void dispose() {
    disposeKeeneticLifecycle();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = keeneticForeground && TickerMode.valuesOf(context).enabled;
    final reading = active
        ? ref.watch(coreKeeneticDashboardTopologyProvider(widget.tile))
        : null;
    final value = reading?.value;
    if (value != null) armKeenetic(value, value.remainingTtlMs);
    final error = reading?.error;
    final failure = error is LarenorServerException
        ? error.code
        : reading?.hasError == true
        ? 'connection_failed'
        : null;
    return CoreKeeneticTopologyDashboardCard(
      title: widget.tile.title ?? 'Keenetic',
      topology: keeneticStale ? null : value,
      failure: failure,
      stale: keeneticStale,
      loading: reading?.isLoading == true,
      onRefresh: active
          ? () => ref.invalidate(
              coreKeeneticDashboardTopologyProvider(widget.tile),
            )
          : null,
    );
  }
}

class CoreKeeneticClientsTile extends ConsumerStatefulWidget {
  const CoreKeeneticClientsTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  ConsumerState<CoreKeeneticClientsTile> createState() =>
      _CoreKeeneticClientsTileState();
}

class _CoreKeeneticClientsTileState
    extends ConsumerState<CoreKeeneticClientsTile>
    with _CoreKeeneticReadonlyTileLifecycle<CoreKeeneticClientsTile> {
  @override
  void initState() {
    super.initState();
    initKeeneticLifecycle();
  }

  @override
  void dispose() {
    disposeKeeneticLifecycle();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = keeneticForeground && TickerMode.valuesOf(context).enabled;
    final reading = active
        ? ref.watch(coreKeeneticDashboardDetailsProvider(widget.tile))
        : null;
    final value = reading?.value;
    if (value != null) armKeenetic(value, value.authority.remainingTtlMs);
    final error = reading?.error;
    final failure = error is LarenorServerException
        ? error.code
        : reading?.hasError == true
        ? 'connection_failed'
        : null;
    return CoreKeeneticClientsDashboardCard(
      title: widget.tile.title ?? 'Keenetic',
      page: keeneticStale ? null : value?.page,
      failure: failure,
      stale: keeneticStale,
      loading: reading?.isLoading == true,
      onRefresh: active
          ? () => ref.invalidate(
              coreKeeneticDashboardDetailsProvider(widget.tile),
            )
          : null,
    );
  }
}

class CoreKeeneticBandwidthTile extends ConsumerStatefulWidget {
  const CoreKeeneticBandwidthTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  ConsumerState<CoreKeeneticBandwidthTile> createState() =>
      _CoreKeeneticBandwidthTileState();
}

class _CoreKeeneticBandwidthTileState
    extends ConsumerState<CoreKeeneticBandwidthTile>
    with _CoreKeeneticReadonlyTileLifecycle<CoreKeeneticBandwidthTile> {
  @override
  void initState() {
    super.initState();
    initKeeneticLifecycle();
  }

  @override
  void dispose() {
    disposeKeeneticLifecycle();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = keeneticForeground && TickerMode.valuesOf(context).enabled;
    final reading = active
        ? ref.watch(coreKeeneticDashboardSnapshotProvider(widget.tile))
        : null;
    final value = reading?.value;
    if (value != null) armKeenetic(value, value.remainingTtlMs);
    final error = reading?.error;
    final failure = error is LarenorServerException
        ? error.code
        : reading?.hasError == true
        ? 'connection_failed'
        : null;
    return CoreKeeneticBandwidthDashboardCard(
      title: widget.tile.title ?? 'Keenetic',
      snapshot: keeneticStale ? null : value,
      failure: failure,
      stale: keeneticStale,
      loading: reading?.isLoading == true,
      onRefresh: active
          ? () => ref.invalidate(
              coreKeeneticDashboardSnapshotProvider(widget.tile),
            )
          : null,
    );
  }
}
