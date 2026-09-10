import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core_ha/data/core_ha_providers.dart';
import '../../core_ha/presentation/core_ha_route.dart';
import '../../core_ha/presentation/core_ha_widgets.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../proxmox/core_power/proxmox_power_discovery.dart';
import '../../proxmox/core_power/proxmox_power_models.dart';
import '../../proxmox/core_power/proxmox_power_panel.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../../server/providers/server_providers.dart';
import '../../server/services/domain/server_service_models.dart';
import '../data/core_proxmox_controller.dart';
import '../data/core_proxmox_providers.dart';
import '../domain/core_proxmox_models.dart';

class CoreProxmoxScreen extends StatelessWidget {
  const CoreProxmoxScreen({super.key, required this.target});
  final HomeResourceRecord target;

  @override
  Widget build(BuildContext context) => CoreHaRoute(
    title: AppLocalizations.of(context).coreProxmoxTitle,
    backKey: 'core-proxmox-back',
    gateCurrent: () => true,
    builder: (owner) => _CoreProxmoxView(
      owner: owner,
      target: target,
      admin: false,
      gateCurrent: () => true,
    ),
  );
}

class CoreProxmoxBindingScreen extends StatelessWidget {
  const CoreProxmoxBindingScreen({
    super.key,
    required this.target,
    required this.gateCurrent,
  });
  final HomeResourceRecord target;
  final bool Function() gateCurrent;

  @override
  Widget build(BuildContext context) => CoreHaRoute(
    title: AppLocalizations.of(context).coreProxmoxBindingTitle,
    backKey: 'core-proxmox-binding-back',
    gateCurrent: gateCurrent,
    builder: (owner) => _CoreProxmoxView(
      owner: owner,
      target: target,
      admin: true,
      gateCurrent: gateCurrent,
    ),
  );
}

class _CoreProxmoxView extends ConsumerStatefulWidget {
  const _CoreProxmoxView({
    required this.owner,
    required this.target,
    required this.admin,
    required this.gateCurrent,
  });
  final CoreHaOwner owner;
  final HomeResourceRecord target;
  final bool admin;
  final bool Function() gateCurrent;

  @override
  ConsumerState<_CoreProxmoxView> createState() => _CoreProxmoxViewState();
}

class _CoreProxmoxViewState extends ConsumerState<_CoreProxmoxView> {
  late final CoreProxmoxSelection _selection = (
    owner: widget.owner,
    target: widget.target,
    admin: widget.admin,
  );
  late final CoreProxmoxController _controller;
  late final ServerAccountController _account;
  late final int _accountGeneration;
  late final ServerSession? _session;
  LarenorServerApi? _powerDiscoveryApi;
  ServerService? _service;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountGeneration = _account.generation;
    _session = _account.session;
    if (_session case final session?) {
      _powerDiscoveryApi = ref.read(coreProxmoxApiFactoryProvider)(
        session.endpoint,
      );
    }
    _controller = ref.read(coreProxmoxControllerProvider(_selection));
    _controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current()) _controller.setVisible(true);
    });
  }

  bool _current() {
    final session = _account.session;
    return mounted &&
        widget.owner.isCurrent &&
        widget.gateCurrent() &&
        _account.generation == _accountGeneration &&
        identical(session, _session) &&
        (!widget.admin || session?.user.canAdminister == true) &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent == true;
  }

  void _changed() {
    if (!_controller.fresh || _controller.preview == null) _service = null;
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _powerDiscoveryApi?.close();
    super.dispose();
  }

  String _error(String? code, AppLocalizations l) => switch (code) {
    'forbidden' || 'not_found' => l.coreProxmoxPermission,
    'proxmox_upstream_unauthorized' => l.coreProxmoxUpstreamAuth,
    'proxmox_upstream_unavailable' ||
    'connection_failed' ||
    'timeout' => l.coreProxmoxOffline,
    'proxmox_summary_unsupported' ||
    'invalid_response' => l.coreProxmoxUnsupported,
    'proxmox_binding_changed' || 'revision_conflict' => l.coreProxmoxChanged,
    'proxmox_preview_invalid' => l.coreProxmoxPreviewExpired,
    _ => l.coreProxmoxError,
  };

  Widget _message(String key, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Semantics(liveRegion: true, child: Text(text, key: ValueKey(key))),
  );

  @override
  Widget build(BuildContext context) {
    ref.watch(coreProxmoxControllerProvider(_selection));
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (_, _) {
        final c = _controller, operation = c.epoch;
        bool current() => _current();
        VoidCallback? guarded(VoidCallback? callback) =>
            callback == null || !current()
            ? null
            : () {
                if (current() && operation == c.epoch) callback();
              };
        Widget button(
          String key,
          String label,
          VoidCallback? callback, {
          bool? selected,
        }) => CoreHaButton(
          key: ValueKey(key),
          label: label,
          onPressed: guarded(callback),
          selected: selected,
          isCurrent: current,
        );
        final summary = widget.admin ? c.preview?.summary : c.snapshot?.summary;
        return CoreHaPage(
          key: ValueKey(
            widget.admin ? 'core-proxmox-binding' : 'core-proxmox-summary',
          ),
          title: widget.admin ? l.coreProxmoxBindingTitle : l.coreProxmoxTitle,
          backKey: widget.admin
              ? 'core-proxmox-binding-back'
              : 'core-proxmox-back',
          onBack: guarded(() => Navigator.of(context).maybePop()),
          slivers: [
            coreHaBlock([
              Semantics(
                header: true,
                child: Text(
                  c.record?.label ?? widget.target.label,
                  style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
                ),
              ),
              const SizedBox(height: 8),
              Text(l.coreProxmoxReadOnly),
              button(
                'core-proxmox-refresh',
                l.commonRefresh,
                c.canRefresh ? () => unawaited(c.refresh()) : null,
              ),
              if (c.busy)
                _message('core-proxmox-loading', l.coreProxmoxLoading),
              if (!c.fresh && !c.busy)
                _message('core-proxmox-required', l.coreProxmoxRequired),
              if (c.failure != null)
                _message('core-proxmox-error', _error(c.failure, l)),
              if (c.stale)
                _message(
                  'core-proxmox-stale',
                  widget.admin
                      ? l.coreProxmoxPreviewExpired
                      : l.coreProxmoxStale,
                ),
              if (c.uncertain)
                _message('core-proxmox-uncertain', l.coreProxmoxUncertain),
              if (c.saved) _message('core-proxmox-saved', l.coreProxmoxSaved),
              if (widget.admin) ..._admin(c, l, button, current),
              if (summary != null) CoreProxmoxSummaryPanel(summary: summary),
            ]),
          ],
        );
      },
    );
  }

  List<Widget> _admin(
    CoreProxmoxController c,
    AppLocalizations l,
    Widget Function(String, String, VoidCallback?, {bool? selected}) button,
    bool Function() current,
  ) {
    final preview = c.preview;
    if (preview != null) {
      return [
        const SizedBox(height: 12),
        Text(l.coreProxmoxPreviewReady),
        button(
          'core-proxmox-preview-cancel',
          l.commonCancel,
          c.canConfirm
              ? () => unawaited(c.cancel(preview, isCurrent: current))
              : null,
        ),
        button(
          'core-proxmox-preview-confirm',
          l.coreProxmoxConfirm,
          c.canConfirm
              ? () => unawaited(c.confirm(preview, isCurrent: current))
              : null,
        ),
      ];
    }
    final resource = c.record ?? widget.target;
    final discoveryApi = _powerDiscoveryApi;
    final session = _session;
    return [
      const SizedBox(height: 12),
      Semantics(header: true, child: Text(l.coreProxmoxServices)),
      if (c.loaded && c.services.isEmpty) Text(l.coreProxmoxNoServices),
      for (final service in c.services)
        button(
          'core-proxmox-service-${service.id}',
          '${service.name} · ${service.baseUrl}',
          c.canPreview
              ? () {
                  _service = service;
                  unawaited(c.prepare(service, isCurrent: current));
                }
              : null,
          selected: identical(_service, service),
        ),
      const SizedBox(height: 12),
      if (discoveryApi != null && session != null && c.loaded)
        CoreProxmoxTargetDiscoveryEntry(
          key: ValueKey(
            'core-proxmox-power-discovery-${resource.id}-${resource.revision}-${resource.aclRevision}',
          ),
          api: discoveryApi,
          accessToken: session.accessToken,
          resource: resource,
          isAdmin: session.user.canAdminister,
          current: current,
          onOpen: (target) {
            if (!current()) return;
            Navigator.of(context).push<void>(
              CupertinoPageRoute(
                builder: (_) => CoreProxmoxPowerCommandScreen(
                  target: target,
                  canWrite: resource.canWrite,
                  gateCurrent: widget.gateCurrent,
                ),
              ),
            );
          },
        )
      else
        ProxmoxPowerEntry(
          isAdmin: true,
          canWrite: false,
          target: null,
          current: current,
          onOpen: (_) {},
        ),
    ];
  }
}

/// Command route reached from the existing Settings PIN-protected Proxmox
/// resource editor. It binds one exact target to the current admin account and
/// retires all pending work on route, account, lifecycle or PIN changes.
class CoreProxmoxPowerCommandScreen extends ConsumerWidget {
  const CoreProxmoxPowerCommandScreen({
    super.key,
    required this.target,
    required this.canWrite,
    required this.gateCurrent,
  });

  final ProxmoxPowerTarget target;
  final bool canWrite;
  final bool Function() gateCurrent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = Localizations.localeOf(context).languageCode == 'tr';
    return CoreHaRoute(
      title: tr ? 'Güç denetimleri' : 'Power controls',
      backKey: 'core-proxmox-power-back',
      gateCurrent: gateCurrent,
      builder: (owner) {
        final account = ref.read(serverAccountControllerProvider);
        final session = account.session;
        if (session == null ||
            session.user.canAdminister != true ||
            session.context?.coreId != target.coreId ||
            session.context?.homeId != target.homeId) {
          return CoreHaPage(
            title: tr ? 'Güç denetimleri' : 'Power controls',
            backKey: 'core-proxmox-power-back',
            onBack: null,
            slivers: [
              coreHaBlock([
                Text(
                  tr
                      ? 'Doğrulanmış yönetici oturumu gereklidir.'
                      : 'A verified administrator session is required.',
                ),
              ]),
            ],
          );
        }
        return _CoreProxmoxPowerPage(
          owner: owner,
          gateCurrent: gateCurrent,
          account: account,
          session: session,
          factory: ref.read(coreProxmoxApiFactoryProvider),
          target: target,
          canWrite: canWrite,
        );
      },
    );
  }
}

class _CoreProxmoxPowerPage extends StatefulWidget {
  const _CoreProxmoxPowerPage({
    required this.owner,
    required this.gateCurrent,
    required this.account,
    required this.session,
    required this.factory,
    required this.target,
    required this.canWrite,
  });

  final CoreHaOwner owner;
  final bool Function() gateCurrent;
  final ServerAccountController account;
  final ServerSession session;
  final ServerApiFactory factory;
  final ProxmoxPowerTarget target;
  final bool canWrite;

  @override
  State<_CoreProxmoxPowerPage> createState() => _CoreProxmoxPowerPageState();
}

class _CoreProxmoxPowerPageState extends State<_CoreProxmoxPowerPage> {
  late final int _generation = widget.account.generation;
  late final LarenorServerApi _api = widget.factory(widget.session.endpoint);

  bool _current() {
    final active = widget.account.session;
    return mounted &&
        widget.owner.isCurrent &&
        widget.gateCurrent() &&
        widget.account.generation == _generation &&
        identical(active, widget.session) &&
        active?.user.canAdminister == true &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent == true;
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = Localizations.localeOf(context).languageCode == 'tr';
    return CoreHaPage(
      title: tr ? 'Güç denetimleri' : 'Power controls',
      backKey: 'core-proxmox-power-back',
      onBack: _current() ? () => Navigator.of(context).maybePop() : null,
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: CoreProxmoxPowerPanel(
            api: _api,
            accessToken: widget.session.accessToken,
            target: widget.target,
            isAdmin: true,
            canWrite: widget.canWrite,
            current: _current,
          ),
        ),
      ],
    );
  }
}

class CoreProxmoxSummaryPanel extends StatelessWidget {
  const CoreProxmoxSummaryPanel({
    super.key,
    required this.summary,
    this.compact = false,
  });
  final CoreProxmoxSummary summary;
  final bool compact;

  String _percent(double value) => '${(value * 100).round()}%';
  String _bytes(int value) {
    const gib = 1024 * 1024 * 1024;
    return '${(value / gib).toStringAsFixed(value >= 10 * gib ? 0 : 1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget card(
      String key,
      String title,
      String status,
      List<String> metrics,
    ) => Semantics(
      container: true,
      key: ValueKey('core-proxmox-$key'),
      label: '$title, $status, ${metrics.join(', ')}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(status),
              for (final metric in metrics)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(metric),
                ),
            ],
          ),
        ),
      ),
    );
    final cards = <Widget>[
      for (final node in summary.nodes)
        card(
          'node-${node.name}',
          node.name,
          node.status == CoreProxmoxNodeStatus.online
              ? l.coreProxmoxOnline
              : l.coreProxmoxOfflineState,
          [
            '${l.coreProxmoxCpu}: ${_percent(node.cpuRatio)}',
            '${l.coreProxmoxMemory}: ${_bytes(node.memoryUsedBytes)} / ${_bytes(node.memoryTotalBytes)}',
            '${l.coreProxmoxUptime}: ${node.uptime.inHours} h',
          ],
        ),
      for (final guest in summary.guests)
        card(
          'guest-${guest.kind.name}-${guest.vmId}',
          '${guest.kind == CoreProxmoxGuestKind.qemu ? l.coreProxmoxVm : l.coreProxmoxContainer} #${guest.vmId} · ${guest.name}',
          guest.status == CoreProxmoxGuestStatus.running
              ? l.coreProxmoxRunning
              : l.coreProxmoxStopped,
          [
            '${l.coreProxmoxNode}: ${guest.node}',
            '${l.coreProxmoxCpu}: ${_percent(guest.cpuRatio)}',
            '${l.coreProxmoxMemory}: ${_bytes(guest.memoryUsedBytes)} / ${_bytes(guest.memoryTotalBytes)}',
          ],
        ),
      for (final storage in summary.storages)
        card(
          'storage-${storage.node}-${storage.name}',
          '${storage.name} · ${storage.kind}',
          storage.active ? l.coreProxmoxActive : l.coreProxmoxInactive,
          [
            '${l.coreProxmoxNode}: ${storage.node}',
            '${l.coreProxmoxDisk}: ${_bytes(storage.usedBytes)} / ${_bytes(storage.totalBytes)}',
          ],
        ),
    ];
    if (cards.isEmpty) return Text(l.coreProxmoxEmpty);
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaled = MediaQuery.textScalerOf(context).scale(17);
        final columns = !compact && constraints.maxWidth >= 680 && scaled <= 28
            ? 2
            : 1;
        final width = columns == 2
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final value in cards) SizedBox(width: width, child: value),
            ],
          ),
        );
      },
    );
  }
}
