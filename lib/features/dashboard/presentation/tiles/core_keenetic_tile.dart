import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/home_session_controller.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/connection_evidence_status.dart';
import '../../../health/data/connection_evidence.dart';
import '../../../keenetic/core/data/core_keenetic_dashboard_providers.dart';
import '../../../keenetic/core/domain/core_keenetic_models.dart';
import '../../../keenetic/core/presentation/core_keenetic_screen.dart';
import '../../../server/domain/server_models.dart';
import '../../domain/tile_config.dart';
import 'dashboard_tile_button.dart';

String _rate(int? value, AppLocalizations l) {
  if (value == null) return l.commonUnknown;
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)} MB/s';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)} KB/s';
  return '$value B/s';
}

String _uptime(int seconds) {
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  return days > 0 ? '${days}d ${hours}h' : '${hours}h';
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

class CoreKeeneticDashboardCard extends StatelessWidget {
  const CoreKeeneticDashboardCard({
    super.key,
    required this.title,
    required this.snapshot,
    required this.failure,
    required this.stale,
    required this.loading,
    required this.onPressed,
  });
  final String title;
  final CoreKeeneticSnapshot? snapshot;
  final String? failure;
  final bool stale, loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), value = snapshot?.telemetry;
    final evidence = loading
        ? const ConnectionEvidence.connecting()
        : stale
        ? ConnectionEvidence.stale(snapshot?.observedAt)
        : failure == 'forbidden' ||
              failure == 'unauthorized' ||
              failure == 'keenetic_upstream_denied'
        ? const ConnectionEvidence.permissionDenied()
        : failure == 'keenetic_snapshot_unsupported' ||
              failure == 'invalid_response' ||
              failure == 'resource_changed' ||
              failure == 'conflict'
        ? const ConnectionEvidence.error()
        : failure != null
        ? const ConnectionEvidence.unavailable()
        : snapshot != null
        ? ConnectionEvidence.verified(snapshot!.observedAt)
        : const ConnectionEvidence.saved();
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
    final lines = value == null
        ? <String>[]
        : [
            '${l.coreKeeneticPublicIp}: ${value.status.publicIp ?? l.commonUnknown}',
            '${l.keeneticDownloadRate}: ${_rate(value.traffic.downloadBps, l)} · ${l.keeneticUploadRate}: ${_rate(value.traffic.uploadBps, l)}',
            'CPU ${_percent(value.status.cpuPercent, l)} · RAM ${_percent(value.status.memoryPercent, l)} · ${l.keeneticConnectedDevices}: ${value.onlineHosts}',
            '${l.keeneticUptime}: ${_uptime(value.status.uptimeSeconds)}',
          ];
    final evidenceLabels = connectionEvidenceLabels(
      l,
      evidence,
      showTimestamp: false,
    );
    final semantics =
        '$title. ${evidenceLabels.join('. ')}. $state. ${lines.join('. ')}';
    return DashboardTileButton(
      key: const ValueKey('core-keenetic-dashboard-card'),
      label: semantics,
      onPressed: onPressed,
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
                Icon(
                  value?.status.online == true
                      ? CupertinoIcons.wifi
                      : CupertinoIcons.wifi_slash,
                  size: 20,
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
            if (lines.isNotEmpty)
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final height =
                        MediaQuery.textScalerOf(context)
                            .scale(AppText.footnote.fontSize!) *
                        1.35;
                    final count = (constraints.maxHeight / height)
                        .floor()
                        .clamp(0, lines.length);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in lines.take(count))
                          SizedBox(
                            height: height,
                            child: Text(
                              line,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.footnote.copyWith(
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
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
    );
  }
}
