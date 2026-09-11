import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/core_infrastructure_evidence.dart';
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
    'keenetic_snapshot_changed' => l.coreKeeneticChanged,
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
        final evidence = coreInfrastructureEvidence(
          busy: c.busy,
          stale: c.stale,
          failure: c.failure,
          verifiedAt: c.snapshot?.observedAt,
          transportObserved: c.preview != null,
        );
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
              const SizedBox(height: 8),
              CoreInfrastructureEvidenceStatus(
                surface: 'keenetic-connection',
                evidence: evidence,
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
              if (telemetry != null || c.details != null || c.failure != null)
                CoreKeeneticDetailsPanel(
                  page: c.details,
                  enabled: c.fresh && !c.busy && !c.stale,
                  failure: c.failure,
                  stale: c.stale,
                  isCurrent: live,
                  onRefresh: c.canRefresh ? () => unawaited(c.refresh()) : null,
                  onLoadMore: c.details?.nextAfter != null && c.fresh && !c.busy
                      ? () => unawaited(c.loadMoreDetails())
                      : null,
                ),
              if (c.topology != null || c.topologyFailure != null)
                CoreKeeneticTopologyPanel(
                  topology: c.topology,
                  failure: c.topologyFailure,
                  enabled: c.fresh && !c.busy && !c.stale,
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

/// Read-only, private mesh graph and Wi-Fi distribution for tablet/DeX.
class CoreKeeneticTopologyPanel extends StatefulWidget {
  const CoreKeeneticTopologyPanel({
    super.key,
    required this.topology,
    this.failure,
    required this.enabled,
    required this.isCurrent,
  });
  final CoreKeeneticTopologySnapshot? topology;
  final String? failure;
  final bool enabled;
  final bool Function() isCurrent;
  @override
  State<CoreKeeneticTopologyPanel> createState() =>
      _CoreKeeneticTopologyPanelState();
}

class _CoreKeeneticTopologyPanelState extends State<CoreKeeneticTopologyPanel> {
  String? _selected;

  String _backhaul(CoreKeeneticBackhaul value) => switch (value) {
    CoreKeeneticBackhaul.ethernet => 'Ethernet',
    CoreKeeneticBackhaul.wifi_2_4 => 'Wi-Fi 2.4',
    CoreKeeneticBackhaul.wifi_5 => 'Wi-Fi 5',
    CoreKeeneticBackhaul.wifi_6 => 'Wi-Fi 6',
    CoreKeeneticBackhaul.unknown => '—',
  };

  String _quality(CoreKeeneticBackhaulQuality value, AppLocalizations l) =>
      switch (value) {
        CoreKeeneticBackhaulQuality.excellent => l.coreKeeneticMeshExcellent,
        CoreKeeneticBackhaulQuality.good => l.coreKeeneticMeshGood,
        CoreKeeneticBackhaulQuality.fair => l.coreKeeneticMeshFair,
        CoreKeeneticBackhaulQuality.poor => l.coreKeeneticMeshPoor,
        CoreKeeneticBackhaulQuality.unknown => l.coreKeeneticMeshUnknown,
      };

  Widget _node(CoreKeeneticMeshNode node, AppLocalizations l) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Semantics(
      button: true,
      selected: _selected == node.id,
      label:
          '${node.name}, ${node.online ? l.keeneticOnline : l.keeneticOffline}',
      child: ExcludeSemantics(
        child: CupertinoButton(
          minimumSize: const Size(48, 48),
          alignment: AlignmentDirectional.centerStart,
          color: _selected == node.id
              ? CupertinoTheme.of(context).primaryColor.withValues(alpha: .12)
              : CupertinoColors.systemGrey6.resolveFrom(context),
          onPressed: widget.enabled && widget.isCurrent()
              ? () => setState(() => _selected = node.id)
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(node.name),
              Text(
                node.online ? l.keeneticOnline : l.keeneticOffline,
                style: AppText.footnote,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _metric(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );

  Widget _detail(CoreKeeneticMeshNode node, AppLocalizations l) =>
      SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(node.name, style: AppText.headline),
            _metric(
              node.role == CoreKeeneticMeshRole.controller
                  ? l.coreKeeneticMeshController
                  : l.coreKeeneticMeshExtender,
              node.model,
            ),
            _metric(
              l.coreKeeneticStatus,
              node.online ? l.keeneticOnline : l.keeneticOffline,
            ),
            if (node.backhaul != null)
              _metric(l.coreKeeneticMeshBackhaul, _backhaul(node.backhaul!)),
            if (node.quality != null)
              _metric(l.coreKeeneticMeshQuality, _quality(node.quality!, l)),
            if (node.pathCost != null)
              _metric(l.coreKeeneticMeshPathCost, '${node.pathCost}'),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), topology = widget.topology;
    final selected = topology?.nodes
        .where((node) => node.id == _selected)
        .firstOrNull;
    Widget nodes() => ListView(
      children: [
        for (final node in topology?.nodes ?? const <CoreKeeneticMeshNode>[])
          _node(node, l),
      ],
    );
    final error = widget.failure == 'keenetic_snapshot_unsupported'
        ? l.coreKeeneticMeshUnsupported
        : l.coreKeeneticMeshUnavailable;
    return Semantics(
      container: true,
      readOnly: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          Semantics(
            header: true,
            child: Text(l.coreKeeneticMeshTitle, style: AppText.headline),
          ),
          if (widget.failure != null)
            Semantics(liveRegion: true, child: Text(error)),
          if (topology != null) ...[
            LayoutBuilder(
              builder: (context, constraints) => SizedBox(
                height: constraints.maxWidth >= 900 ? 300 : 350,
                child: constraints.maxWidth >= 900
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 2, child: nodes()),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 3,
                            child: selected == null
                                ? Center(child: Text(l.coreKeeneticMeshNoNodes))
                                : _detail(selected, l),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          Expanded(child: nodes()),
                          const SizedBox(height: 8),
                          Expanded(
                            child: selected == null
                                ? Center(child: Text(l.coreKeeneticMeshNoNodes))
                                : _detail(selected, l),
                          ),
                        ],
                      ),
              ),
            ),
            Semantics(
              header: true,
              child: Text(l.coreKeeneticMeshNetworks, style: AppText.headline),
            ),
            for (final network in topology.networks)
              Semantics(
                container: true,
                readOnly: true,
                label:
                    '${network.ssid}, ${network.band} GHz, ${network.clientCount}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: ExcludeSemantics(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text(network.ssid),
                        Text('${network.band} GHz'),
                        Text(
                          '${l.coreKeeneticDetailsChannel} ${network.channel}',
                        ),
                        Text(
                          '${l.coreKeeneticMeshClients} ${network.clientCount}',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

enum _DetailFilter { all, interfaces, clients }

/// Snapshot-bound, read-only master-detail list for tablets and DeX windows.
class CoreKeeneticDetailsPanel extends StatefulWidget {
  const CoreKeeneticDetailsPanel({
    super.key,
    required this.page,
    required this.enabled,
    this.failure,
    this.stale = false,
    required this.isCurrent,
    required this.onRefresh,
    required this.onLoadMore,
  });
  final CoreKeeneticDetailsPage? page;
  final bool enabled, stale;
  final String? failure;
  final bool Function() isCurrent;
  final VoidCallback? onRefresh, onLoadMore;
  @override
  State<CoreKeeneticDetailsPanel> createState() =>
      _CoreKeeneticDetailsPanelState();
}

class _CoreKeeneticDetailsPanelState extends State<CoreKeeneticDetailsPanel> {
  String _query = '';
  _DetailFilter _filter = _DetailFilter.all;
  String? _selected;

  String _failure(AppLocalizations l) => switch (widget.failure) {
    'keenetic_snapshot_unsupported' ||
    'invalid_response' => l.coreKeeneticUnsupported,
    'keenetic_snapshot_changed' ||
    'keenetic_binding_changed' => l.coreKeeneticChanged,
    'forbidden' || 'unauthorized' => l.coreKeeneticPermission,
    _ => l.coreKeeneticOffline,
  };

  List<CoreKeeneticDetail> get _entries {
    final query = _query.trim().toLowerCase();
    return (widget.page?.entries ?? const <CoreKeeneticDetail>[])
        .where((item) {
          if (_filter == _DetailFilter.interfaces &&
              item is! CoreKeeneticInterfaceDetail) {
            return false;
          }
          if (_filter == _DetailFilter.clients &&
              item is! CoreKeeneticClientDetail) {
            return false;
          }
          if (query.isEmpty) return true;
          final searchable = switch (item) {
            CoreKeeneticInterfaceDetail value =>
              '${value.name} ${value.address ?? ''} ${value.ssid ?? ''} '
                  '${value.interfaceKind.name}',
            CoreKeeneticClientDetail value =>
              '${value.name} ${value.ipAddress} ${value.macHash} '
                  '${value.interfaceId}',
          };
          return searchable.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  void _invoke(VoidCallback? callback) {
    if (callback != null && widget.enabled && widget.isCurrent()) callback();
  }

  Widget _entry(CoreKeeneticDetail item, AppLocalizations l) {
    final selected = _selected == '${item.runtimeType}:${item.id}';
    final semantics = switch (item) {
      CoreKeeneticInterfaceDetail value =>
        '${value.name}, ${value.ssid ?? value.address ?? value.interfaceKind.name}',
      CoreKeeneticClientDetail value =>
        '${value.name}, ${value.ipAddress}, ${value.macHash}',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Semantics(
        button: true,
        selected: selected,
        label: semantics,
        child: ExcludeSemantics(
          child: CupertinoButton(
            minimumSize: const Size(48, 48),
            alignment: AlignmentDirectional.centerStart,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            color: selected
                ? CupertinoTheme.of(context).primaryColor.withValues(alpha: .12)
                : CupertinoColors.systemGrey6.resolveFrom(context),
            onPressed: widget.enabled && widget.isCurrent()
                ? () => setState(
                    () => _selected = '${item.runtimeType}:${item.id}',
                  )
                : null,
            child: Text(item.name, textAlign: TextAlign.start),
          ),
        ),
      ),
    );
  }

  Widget _metric(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );

  Widget _detail(CoreKeeneticDetail item, AppLocalizations l) {
    final values = switch (item) {
      CoreKeeneticInterfaceDetail value => <(String, String)>[
        (
          l.coreKeeneticDetailsInterface,
          value.interfaceKind.name.toUpperCase(),
        ),
        (l.coreKeeneticDetailsAddress, value.address ?? l.commonUnknown),
        (l.coreKeeneticDetailsSsid, value.ssid ?? l.commonUnknown),
        (l.coreKeeneticDetailsBand, value.band ?? l.commonUnknown),
        (
          l.coreKeeneticDetailsChannel,
          value.channel?.toString() ?? l.commonUnknown,
        ),
        (
          l.coreKeeneticDetailsSignal,
          value.signalDbm == null ? l.commonUnknown : '${value.signalDbm} dBm',
        ),
      ],
      CoreKeeneticClientDetail value => <(String, String)>[
        (l.coreKeeneticDetailsAddress, value.ipAddress),
        (l.coreKeeneticDetailsIdentity, value.macHash),
        (l.coreKeeneticDetailsInterface, value.interfaceId),
        (l.coreKeeneticDetailsAccess, value.internetAccess ?? l.commonUnknown),
        (l.coreKeeneticDetailsBand, value.band ?? l.commonUnknown),
        (
          l.coreKeeneticDetailsSignal,
          value.signalDbm == null ? l.commonUnknown : '${value.signalDbm} dBm',
        ),
      ],
    };
    return Semantics(
      container: true,
      readOnly: true,
      label: item.name,
      child: SingleChildScrollView(
        key: ValueKey('core-keenetic-detail-${item.id}'),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(item.name, style: AppText.headline),
            for (final (label, value) in values) _metric(label, value),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), entries = _entries;
    final selectedKey = _selected;
    final selected = entries
        .where((item) => '${item.runtimeType}:${item.id}' == selectedKey)
        .firstOrNull;
    Widget list() => ListView(
      key: const ValueKey('core-keenetic-details-list'),
      children: [
        for (final item in entries) _entry(item, l),
        if (entries.isEmpty) Text(l.coreKeeneticDetailsEmpty),
        if (widget.page?.nextAfter != null)
          CoreHaButton(
            key: const ValueKey('core-keenetic-details-load-more'),
            label: l.coreKeeneticDetailsLoadMore,
            isCurrent: widget.isCurrent,
            onPressed: widget.enabled ? () => _invoke(widget.onLoadMore) : null,
          ),
      ],
    );
    return Semantics(
      container: true,
      readOnly: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          Semantics(
            header: true,
            child: Text(l.coreKeeneticDetailsTitle, style: AppText.headline),
          ),
          CupertinoSearchTextField(
            placeholder: l.coreKeeneticDetailsSearch,
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 8),
          CupertinoSlidingSegmentedControl<_DetailFilter>(
            groupValue: _filter,
            onValueChanged: (value) {
              if (value != null && widget.enabled && widget.isCurrent()) {
                setState(() {
                  _filter = value;
                  _selected = null;
                });
              }
            },
            children: {
              _DetailFilter.all: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(l.coreKeeneticDetailsAll),
              ),
              _DetailFilter.interfaces: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(l.coreKeeneticDetailsInterfaces),
              ),
              _DetailFilter.clients: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(l.coreKeeneticDetailsClients),
              ),
            },
          ),
          CoreHaButton(
            key: const ValueKey('core-keenetic-details-refresh'),
            label: l.commonRefresh,
            isCurrent: widget.isCurrent,
            onPressed: widget.enabled ? () => _invoke(widget.onRefresh) : null,
          ),
          if (widget.stale)
            Semantics(liveRegion: true, child: Text(l.coreKeeneticStale)),
          if (widget.failure != null)
            Semantics(liveRegion: true, child: Text(_failure(l))),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 900) {
                return SizedBox(
                  height: 340,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 2, child: list()),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 3,
                        child: selected == null
                            ? Center(child: Text(l.coreKeeneticDetailsEmpty))
                            : _detail(selected, l),
                      ),
                    ],
                  ),
                );
              }
              return SizedBox(
                height: 340,
                child: Column(
                  children: [
                    Expanded(child: list()),
                    const SizedBox(height: 8),
                    Expanded(
                      child: selected == null
                          ? Center(child: Text(l.coreKeeneticDetailsEmpty))
                          : _detail(selected, l),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
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

  String _uptime(int seconds, AppLocalizations l) {
    final days = seconds ~/ 86400, hours = seconds.remainder(86400) ~/ 3600;
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
    final guest = value.guestInterfaces;
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
            _uptime(value.status.uptimeSeconds, l),
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
            'core-keenetic-traffic',
            l.coreKeeneticTrafficTotal,
            '${_bytes(value.traffic.rxBytes)} ↓ / '
                '${_bytes(value.traffic.txBytes)} ↑',
          ),
          _metric(
            'core-keenetic-firmware',
            l.keeneticFirmware,
            value.status.firmware ?? l.commonUnknown,
          ),
          _metric(
            'core-keenetic-guest',
            l.coreKeeneticGuestWifi,
            guest.isEmpty
                ? l.coreKeeneticGuestUnavailable
                : guest.any((item) => item.online)
                ? l.coreKeeneticGuestEnabled
                : l.coreKeeneticGuestDisabled,
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
