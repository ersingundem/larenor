import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../core_ha/data/core_ha_providers.dart';
import '../../../core_ha/presentation/core_ha_route.dart';
import '../../../core_ha/presentation/core_ha_widgets.dart';
import '../../../home_resources/domain/home_resource_models.dart';
import '../../../server/services/domain/server_service_models.dart';
import '../data/core_keenetic_controller.dart';
import '../data/core_keenetic_providers.dart';
import '../domain/core_keenetic_models.dart';

class CoreKeeneticScreen extends StatelessWidget {
  const CoreKeeneticScreen({
    super.key,
    required this.target,
    required this.admin,
  });
  final HomeResourceRecord target;
  final bool admin;
  @override
  Widget build(BuildContext context) => CoreHaRoute(
    title: admin
        ? AppLocalizations.of(context).coreKeeneticBindingTitle
        : AppLocalizations.of(context).coreKeeneticTitle,
    backKey: 'core-keenetic-back',
    gateCurrent: () => true,
    builder: (owner) => _View(owner: owner, target: target, admin: admin),
  );
}

class _View extends ConsumerStatefulWidget {
  const _View({required this.owner, required this.target, required this.admin});
  final CoreHaOwner owner;
  final HomeResourceRecord target;
  final bool admin;
  @override
  ConsumerState<_View> createState() => _ViewState();
}

class _ViewState extends ConsumerState<_View> {
  late final CoreKeeneticSelection _selection = (
    owner: widget.owner,
    target: widget.target,
    admin: widget.admin,
  );
  late final CoreKeeneticController _controller;
  ServerService? _service;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(coreKeeneticControllerProvider(_selection));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.owner.isCurrent) _controller.setVisible(true);
    });
  }

  String _error(String code, AppLocalizations l) => switch (code) {
    'not_found' => l.coreKeeneticNoBinding,
    'forbidden' => l.coreKeeneticPermission,
    'keenetic_upstream_denied' ||
    'keenetic_upstream_unauthorized' => l.coreKeeneticDenied,
    'keenetic_snapshot_unsupported' ||
    'keenetic_upstream_unsupported' => l.coreKeeneticUnsupported,
    'keenetic_binding_changed' || 'revision_conflict' => l.coreKeeneticChanged,
    'keenetic_preview_invalid' => l.coreKeeneticPreviewExpired,
    'keenetic_upstream_unavailable' ||
    'connection_failed' ||
    'timeout' => l.coreKeeneticOffline,
    _ => l.healthReadError,
  };

  @override
  Widget build(BuildContext context) {
    ref.watch(coreKeeneticControllerProvider(_selection));
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (_, _) {
        final c = _controller,
            telemetry = c.preview?.telemetry ?? c.snapshot?.telemetry;
        if (_service != null &&
            !c.services.any((s) => identical(s, _service))) {
          _service = null;
        }
        final service = _service;
        bool live() => mounted && widget.owner.isCurrent;
        Widget button(
          String key,
          String label,
          VoidCallback? action, {
          bool? selected,
        }) => CoreHaButton(
          key: ValueKey(key),
          label: label,
          selected: selected,
          isCurrent: live,
          onPressed: action == null || !live()
              ? null
              : () {
                  if (live()) action();
                },
        );
        return CoreHaPage(
          key: ValueKey(
            widget.admin ? 'core-keenetic-binding' : 'core-keenetic-snapshot',
          ),
          title: widget.admin
              ? l.coreKeeneticBindingTitle
              : l.coreKeeneticTitle,
          onBack: live() ? () => Navigator.of(context).maybePop() : null,
          slivers: [
            coreHaBlock([
              Semantics(
                header: true,
                child: Text(
                  widget.target.label,
                  style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
                ),
              ),
              button(
                'core-keenetic-refresh',
                l.commonRefresh,
                c.canRefresh ? () => unawaited(c.refresh()) : null,
              ),
              if (c.busy)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    l.coreKeeneticLoading,
                    key: const ValueKey('core-keenetic-loading'),
                  ),
                ),
              if (!c.fresh && !c.busy)
                Semantics(
                  liveRegion: true,
                  child: Text(l.coreKeeneticRequired),
                ),
              if (c.failure != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error(c.failure!, l),
                    key: const ValueKey('core-keenetic-error'),
                  ),
                ),
              if (c.stale)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    l.coreKeeneticStale,
                    key: const ValueKey('core-keenetic-stale'),
                  ),
                ),
              if (c.saved)
                Semantics(liveRegion: true, child: Text(l.coreKeeneticSaved)),
              if (telemetry != null)
                CoreKeeneticTelemetryPanel(
                  telemetry: telemetry,
                  enabled: c.fresh,
                  isCurrent: live,
                ),
              if (!widget.admin && telemetry != null)
                Text(l.coreKeeneticReadOnly, style: AppText.footnote),
              if (widget.admin && c.fresh && c.loaded) ...[
                const SizedBox(height: 20),
                Semantics(
                  header: true,
                  child: Text(l.coreKeeneticService, style: AppText.headline),
                ),
                if (!c.services.any(
                  (value) =>
                      value.verification.state ==
                      ServerServiceVerificationState.authenticated,
                ))
                  Text(l.coreKeeneticNoServices),
                for (final value in c.services)
                  button(
                    'core-keenetic-service-${value.id}',
                    value.name,
                    c.canPreview &&
                            value.verification.state ==
                                ServerServiceVerificationState.authenticated
                        ? () => setState(() => _service = value)
                        : null,
                    selected: identical(value, service),
                  ),
                if (c.preview == null)
                  button(
                    'core-keenetic-preview',
                    l.coreKeeneticPreview,
                    c.canPreview && service != null
                        ? () => unawaited(c.createPreview(service))
                        : null,
                  )
                else ...[
                  button(
                    'core-keenetic-cancel',
                    l.commonCancel,
                    c.canConfirm ? () => unawaited(c.cancelPreview()) : null,
                  ),
                  button(
                    'core-keenetic-confirm',
                    l.coreKeeneticConfirm,
                    c.canConfirm ? () => unawaited(c.confirm()) : null,
                  ),
                ],
              ],
            ]),
          ],
        );
      },
    );
  }
}

/// Responsive read-only panel shared by tablet and DeX layouts.
class CoreKeeneticTelemetryPanel extends StatefulWidget {
  const CoreKeeneticTelemetryPanel({
    super.key,
    required this.telemetry,
    required this.enabled,
    required this.isCurrent,
  });
  final CoreKeeneticTelemetry telemetry;
  final bool enabled;
  final bool Function() isCurrent;
  @override
  State<CoreKeeneticTelemetryPanel> createState() =>
      _CoreKeeneticTelemetryPanelState();
}

class _CoreKeeneticTelemetryPanelState
    extends State<CoreKeeneticTelemetryPanel> {
  String? _interfaceId;
  String _rate(int? bytes, AppLocalizations l) {
    if (bytes == null) return l.commonUnknown;
    if (bytes >= 1000000) return '${(bytes / 1000000).toStringAsFixed(1)} MB/s';
    if (bytes >= 1000) return '${(bytes / 1000).toStringAsFixed(1)} KB/s';
    return '$bytes B/s';
  }

  String _uptime(int seconds) {
    final days = seconds ~/ 86400, hours = seconds.remainder(86400) ~/ 3600;
    return days > 0 ? '$days d $hours h' : '$hours h';
  }

  Widget _metric(String key, String label, String value) => Semantics(
    container: true,
    label: '$label, $value',
    child: Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppText.body)),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: AppText.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), value = widget.telemetry;
    final selected = value.interfaces
        .where((i) => i.id == _interfaceId)
        .firstOrNull;
    return Semantics(
      container: true,
      readOnly: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(l.coreKeeneticStatus, style: AppText.headline),
          ),
          _metric(
            'core-keenetic-online',
            l.keeneticInternetStatus,
            value.status.online ? l.keeneticOnline : l.keeneticOffline,
          ),
          _metric(
            'core-keenetic-public-ip',
            l.coreKeeneticPublicIp,
            value.status.publicIp ?? l.commonUnknown,
          ),
          _metric(
            'core-keenetic-uptime',
            l.keeneticUptime,
            _uptime(value.status.uptimeSeconds),
          ),
          _metric(
            'core-keenetic-download',
            l.keeneticDownloadRate,
            _rate(value.traffic.downloadBps, l),
          ),
          _metric(
            'core-keenetic-upload',
            l.keeneticUploadRate,
            _rate(value.traffic.uploadBps, l),
          ),
          _metric(
            'core-keenetic-cpu',
            l.keeneticCpuUsage,
            value.status.cpuPercent == null
                ? l.commonUnknown
                : '${value.status.cpuPercent!.toStringAsFixed(1)}%',
          ),
          _metric(
            'core-keenetic-memory',
            l.keeneticMemoryUsage,
            value.status.memoryPercent == null
                ? l.commonUnknown
                : '${value.status.memoryPercent!.toStringAsFixed(1)}%',
          ),
          _metric(
            'core-keenetic-hosts',
            l.keeneticConnectedDevices,
            '${value.onlineHosts}',
          ),
          const SizedBox(height: 16),
          Semantics(
            header: true,
            child: Text(l.keeneticInterfaces, style: AppText.headline),
          ),
          for (final item in value.interfaces)
            CoreHaButton(
              key: ValueKey('core-keenetic-interface-${item.id}'),
              label: '${item.name} · ${item.address ?? l.commonUnknown}',
              selected: item.id == _interfaceId,
              isCurrent: widget.isCurrent,
              onPressed: widget.enabled && widget.isCurrent()
                  ? () {
                      if (widget.isCurrent()) {
                        setState(() => _interfaceId = item.id);
                      }
                    }
                  : null,
            ),
          if (selected != null) ...[
            _metric(
              'core-keenetic-interface-rx',
              l.keeneticReceivedTotal,
              '${selected.rxBytes} B',
            ),
            _metric(
              'core-keenetic-interface-tx',
              l.keeneticSentTotal,
              '${selected.txBytes} B',
            ),
          ],
        ],
      ),
    );
  }
}
