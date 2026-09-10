import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_session_controller.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../core_ha/data/core_ha_providers.dart';
import '../../core_ha/presentation/core_ha_route.dart';
import '../../core_ha/presentation/core_ha_widgets.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../navigation/search/domain/local_search_index.dart';
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

typedef CoreProxmoxPowerOpener = void Function(
  BuildContext context,
  ProxmoxPowerTarget target,
  bool canWrite,
);

class CoreProxmoxScreen extends StatelessWidget {
  const CoreProxmoxScreen({
    super.key,
    required this.target,
    this.onOpenPowerControls,
  });
  final HomeResourceRecord target;
  final CoreProxmoxPowerOpener? onOpenPowerControls;

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
      onOpenPowerControls: onOpenPowerControls,
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
    this.onOpenPowerControls,
  });
  final CoreHaOwner owner;
  final HomeResourceRecord target;
  final bool admin;
  final bool Function() gateCurrent;
  final CoreProxmoxPowerOpener? onOpenPowerControls;

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
  int _powerRefreshEpoch = 0;
  ServerService? _service;

  @override
  void initState() {
    super.initState();
    // Bind discovery to the same account instance that owns the verified Core
    // runtime. A separately overridden/default account must never authorize a
    // target read or retain a late discovery result.
    _account = ref.read(homeSessionControllerProvider)!.account;
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

  Future<void> _refreshDetail(CoreProxmoxController controller) async {
    await controller.refresh();
    if (_current()) setState(() => _powerRefreshEpoch++);
  }

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
            if (!widget.admin)
              CupertinoSliverRefreshControl(
                key: const ValueKey('core-proxmox-detail-refresh'),
                onRefresh: () => _refreshDetail(c),
              ),
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
                c.canRefresh
                    ? () => unawaited(
                        widget.admin ? c.refresh() : _refreshDetail(c),
                      )
                    : null,
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
              if (!widget.admin && widget.onOpenPowerControls != null)
                ..._detailPower(c),
              if (summary != null)
                if (widget.admin)
                  CoreProxmoxSummaryPanel(summary: summary)
                else
                  CoreProxmoxDetailExplorer(summary: summary),
            ]),
          ],
        );
      },
    );
  }

  List<Widget> _detailPower(CoreProxmoxController controller) {
    final resource = controller.record ?? widget.target;
    final discoveryApi = _powerDiscoveryApi;
    final session = _session;
    final open = widget.onOpenPowerControls;
    if (session?.user.canAdminister != true) {
      final tr = Localizations.localeOf(context).languageCode == 'tr';
      return [
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: Text(
            tr
                ? 'Salt okunur erişim. Güç denetimleri yönetici ve PIN gerektirir.'
                : 'Read-only access. Power controls require an administrator and PIN.',
          ),
        ),
      ];
    }
    if (discoveryApi == null || session == null || !controller.loaded) {
      return const [];
    }
    return [
      const SizedBox(height: 16),
      CoreProxmoxTargetDiscoveryEntry(
        key: ValueKey(
          'core-proxmox-detail-power-${resource.id}-${resource.revision}-${resource.aclRevision}-$_powerRefreshEpoch',
        ),
        api: discoveryApi,
        accessToken: session.accessToken,
        resource: resource,
        isAdmin: true,
        current: _current,
        onOpen: (target) {
          if (_current()) open?.call(context, target, resource.canWrite);
        },
      ),
    ];
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

enum _CoreProxmoxDetailFilter { all, nodes, guests, storage, tasks }

final class _CoreProxmoxDetailItem {
  const _CoreProxmoxDetailItem({
    required this.key,
    required this.filter,
    required this.section,
    required this.title,
    required this.status,
    required this.metrics,
  });
  final String key, section, title, status;
  final _CoreProxmoxDetailFilter filter;
  final List<String> metrics;
  String get searchable =>
      foldSearchText('$section $title $status ${metrics.join(' ')}');
}

/// Tablet-first read-only inventory for a verified Core snapshot. Task history
/// remains an explicit unavailable section until the strict snapshot contract
/// carries bounded task records.
class CoreProxmoxDetailExplorer extends StatefulWidget {
  const CoreProxmoxDetailExplorer({super.key, required this.summary});
  final CoreProxmoxSummary summary;

  @override
  State<CoreProxmoxDetailExplorer> createState() =>
      _CoreProxmoxDetailExplorerState();
}

class _CoreProxmoxDetailExplorerState extends State<CoreProxmoxDetailExplorer> {
  final _search = TextEditingController();
  _CoreProxmoxDetailFilter _filter = _CoreProxmoxDetailFilter.all;
  String? _selected;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _percent(double value) => '${(value * 100).round()}%';
  String _bytes(int value) {
    const gib = 1024 * 1024 * 1024;
    return '${(value / gib).toStringAsFixed(value >= 10 * gib ? 0 : 1)} GB';
  }

  List<_CoreProxmoxDetailItem> _items(bool tr) => [
    for (final node in widget.summary.nodes)
      _CoreProxmoxDetailItem(
        key: 'node-${node.name}',
        filter: _CoreProxmoxDetailFilter.nodes,
        section: tr ? 'Düğümler' : 'Nodes',
        title: node.name,
        status: node.status == CoreProxmoxNodeStatus.online
            ? (tr ? 'Çevrimiçi' : 'Online')
            : (tr ? 'Çevrimdışı' : 'Offline'),
        metrics: [
          'CPU ${_percent(node.cpuRatio)}',
          'RAM ${_bytes(node.memoryUsedBytes)} / ${_bytes(node.memoryTotalBytes)}',
          '${tr ? 'Çalışma süresi' : 'Uptime'} ${node.uptime.inHours} h',
        ],
      ),
    for (final guest in widget.summary.guests)
      _CoreProxmoxDetailItem(
        key: 'guest-${guest.kind.name}-${guest.vmId}',
        filter: _CoreProxmoxDetailFilter.guests,
        section: tr
            ? 'Sanal makineler ve konteynerler'
            : 'Virtual machines & containers',
        title:
            '${guest.kind == CoreProxmoxGuestKind.qemu ? (tr ? 'QEMU sanal makinesi' : 'QEMU VM') : (tr ? 'LXC konteyneri' : 'LXC container')} #${guest.vmId} · ${guest.name}',
        status: guest.status == CoreProxmoxGuestStatus.running
            ? (tr ? 'Çalışıyor' : 'Running')
            : (tr ? 'Durduruldu' : 'Stopped'),
        metrics: [
          '${tr ? 'Düğüm' : 'Node'} ${guest.node}',
          'CPU ${_percent(guest.cpuRatio)}',
          'RAM ${_bytes(guest.memoryUsedBytes)} / ${_bytes(guest.memoryTotalBytes)}',
        ],
      ),
    for (final storage in widget.summary.storages)
      _CoreProxmoxDetailItem(
        key: 'storage-${storage.node}-${storage.name}',
        filter: _CoreProxmoxDetailFilter.storage,
        section: tr ? 'Depolama' : 'Storage',
        title: '${storage.name} · ${storage.kind}',
        status: storage.active
            ? (tr ? 'Etkin' : 'Active')
            : (tr ? 'Etkin değil' : 'Inactive'),
        metrics: [
          '${tr ? 'Düğüm' : 'Node'} ${storage.node}',
          '${tr ? 'Kullanılan' : 'Used'} ${_bytes(storage.usedBytes)} / ${_bytes(storage.totalBytes)}',
        ],
      ),
    _CoreProxmoxDetailItem(
      key: 'tasks-unavailable',
      filter: _CoreProxmoxDetailFilter.tasks,
      section: tr ? 'Son görevler' : 'Recent tasks',
      title: tr ? 'Görev geçmişi kullanılamıyor' : 'Task history unavailable',
      status: tr
          ? 'Mevcut Core anlık görüntüsü görev geçmişi sunmuyor.'
          : 'The current Core snapshot does not provide task history.',
      metrics: const [],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final tr = Localizations.localeOf(context).languageCode == 'tr';
    final query = foldSearchText(_search.text);
    final all = _items(tr);
    final filtered = all
        .where(
          (item) =>
              (_filter == _CoreProxmoxDetailFilter.all ||
                  item.filter == _filter) &&
              (query.isEmpty || item.searchable.contains(query)),
        )
        .toList(growable: false);
    final selected =
        filtered.where((item) => item.key == _selected).firstOrNull ??
        filtered.firstOrNull;
    String filterLabel(_CoreProxmoxDetailFilter value) => switch (value) {
      _CoreProxmoxDetailFilter.all => tr ? 'Tümü' : 'All',
      _CoreProxmoxDetailFilter.nodes => tr ? 'Düğümler' : 'Nodes',
      _CoreProxmoxDetailFilter.guests => tr ? 'Konuklar' : 'Guests',
      _CoreProxmoxDetailFilter.storage => tr ? 'Depolama' : 'Storage',
      _CoreProxmoxDetailFilter.tasks => tr ? 'Görevler' : 'Tasks',
    };

    Widget list() => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (filtered.isEmpty)
          Semantics(
            liveRegion: true,
            child: Text(tr ? 'Eşleşen öğe yok.' : 'No matching items.'),
          ),
        for (final section in _CoreProxmoxDetailFilter.values.skip(1)) ...[
          if (filtered.any((item) => item.filter == section))
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 4),
              child: Semantics(
                header: true,
                label: filtered
                    .firstWhere((item) => item.filter == section)
                    .section,
                excludeSemantics: true,
                child: Text(
                  filtered.firstWhere((item) => item.filter == section).section,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          for (final item in filtered.where((item) => item.filter == section))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Semantics(
                button: true,
                selected: selected?.key == item.key,
                label:
                    '${item.section}, ${item.title}, ${item.status}, ${item.metrics.join(', ')}',
                excludeSemantics: true,
                child: CupertinoButton.tinted(
                  key: ValueKey('core-proxmox-detail-${item.key}'),
                  minimumSize: const Size.fromHeight(48),
                  alignment: Alignment.centerLeft,
                  onPressed: () => setState(() => _selected = item.key),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title, maxLines: 2),
                      const SizedBox(height: 2),
                      Text(item.status, maxLines: 2),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ],
    );

    Widget details() => DecoratedBox(
      key: const ValueKey('core-proxmox-detail-selection'),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: selected == null
            ? Text(tr ? 'Bir öğe seçin.' : 'Select an item.')
            : Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      selected.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(selected.status),
                    for (final metric in selected.metrics)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(metric),
                      ),
                  ],
                ),
              ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CupertinoSearchTextField(
            key: const ValueKey('core-proxmox-detail-search'),
            placeholder: tr
                ? 'Düğüm, konuk veya depolama ara'
                : 'Search nodes, guests or storage',
            onChanged: (_) => setState(() {}),
            controller: _search,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in _CoreProxmoxDetailFilter.values)
                Semantics(
                  button: true,
                  selected: _filter == value,
                  child: CupertinoButton.tinted(
                    key: ValueKey('core-proxmox-filter-${value.name}'),
                    minimumSize: const Size(88, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    onPressed: () => setState(() {
                      _filter = value;
                      _selected = null;
                    }),
                    child: Text(filterLabel(value)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final twoPane =
                  constraints.maxWidth >= 720 &&
                  MediaQuery.textScalerOf(context).scale(17) <= 28;
              if (!twoPane) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [list(), const SizedBox(height: 12), details()],
                );
              }
              return Row(
                key: const ValueKey('core-proxmox-master-detail'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 340, child: list()),
                  const SizedBox(width: 12),
                  Expanded(child: details()),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
