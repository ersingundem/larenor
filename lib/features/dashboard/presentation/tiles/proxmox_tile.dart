import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/home_session_controller.dart';
import '../../../../core/home_source_store.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../health/data/connection_evidence.dart';
import '../../../core_ha/data/core_ha_providers.dart';
import '../../../core_proxmox/data/core_proxmox_providers.dart';
import '../../../core_proxmox/domain/core_proxmox_models.dart';
import '../../../core_proxmox/presentation/core_proxmox_screen.dart';
import '../../../home_resources/domain/home_resource_models.dart';
import '../../../proxmox/core_power/proxmox_power_discovery.dart';
import '../../../proxmox/core_power/proxmox_power_models.dart';
import '../../../server/data/larenor_server_api.dart';
import '../../../server/domain/server_models.dart';
import '../../../settings/presentation/settings_gate_screen.dart';
import '../../../proxmox/presentation/proxmox_nodes_screen.dart';
import '../../../proxmox/providers/proxmox_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';
import '../../../settings/data/app_service.dart';

class ProxmoxTile extends ConsumerStatefulWidget {
  const ProxmoxTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  ConsumerState<ProxmoxTile> createState() => _ProxmoxTileState();
}

class _ProxmoxTileState extends ConsumerState<ProxmoxTile> {
  late final AppLifecycleListener _lifecycle;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (mounted) {
          setState(() => _foreground = state == AppLifecycleState.resumed);
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final home = ref.watch(homeSessionControllerProvider);
    if (home?.source == HomeSource.verifiedCore) {
      return _CoreProxmoxTile(tile: widget.tile);
    }
    final l10n = AppLocalizations.of(context);
    final config = ref.watch(proxmoxConnectionProvider);
    final configured =
        !config.isLoading && !config.hasError && config.value != null;
    final active = _foreground && TickerMode.valuesOf(context).enabled;
    final reading = configured && active
        ? ref.watch(proxmoxNodesProvider)
        : null;
    final nodes = reading == null || reading.isLoading || reading.hasError
        ? null
        : reading.value;
    String percent(double? value) =>
        value == null || !value.isFinite || value < 0 || value > 1
        ? l10n.commonUnknown
        : '${(value * 100).round()}%';
    return ServiceTileShell(
      icon: CupertinoIcons.square_stack_3d_up,
      service: AppService.proxmox,
      title: widget.tile.title ?? 'Proxmox',
      connected: configured,
      onTap: () {
        if (mounted && active) {
          Navigator.of(context).push(
            CupertinoPageRoute(builder: (_) => const ProxmoxNodesScreen()),
          );
        }
      },
      lines: [
        if (config.isLoading || reading?.isLoading == true)
          l10n.commonLoading
        else if (config.hasError || reading?.hasError == true)
          l10n.healthReadError
        else if (nodes?.isEmpty == true)
          l10n.proxmoxTileNoNodes
        else if (nodes != null)
          for (final node in nodes.take(3))
            '${node.name} · CPU ${percent(node.isOnline ? node.cpuFraction : null)} · RAM ${percent(node.isOnline ? node.memFraction : null)}',
      ],
    );
  }
}

/// Resolves the configured Core resource before delegating snapshot reads to
/// [CoreProxmoxController]. This path never reads Direct Proxmox providers.
class _CoreProxmoxTile extends ConsumerStatefulWidget {
  const _CoreProxmoxTile({required this.tile});
  final TileConfig tile;
  @override
  ConsumerState<_CoreProxmoxTile> createState() => _CoreProxmoxTileState();
}

class _CoreProxmoxTileState extends ConsumerState<_CoreProxmoxTile> {
  AppLifecycleListener? _lifecycle;
  HomeResourceRecord? _target;
  CoreHaOwner? _owner;
  LarenorServerApi? _discoveryApi;
  ProxmoxTargetDiscoveryController? _discovery;
  HomeSessionController? _home;
  Object? _identity;
  int _operation = 0, _accountGeneration = -1;
  bool _foreground = true, _loading = false, _attempted = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (!mounted) return;
        _foreground = state == AppLifecycleState.resumed;
        if (!_foreground) _retire();
        setState(() {});
      },
    );
    _home = ref.read(homeSessionControllerProvider);
    _home?.addListener(_authorityChanged);
    _home?.account.addListener(_authorityChanged);
    _home?.interaction.addListener(_authorityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  void _authorityChanged() {
    if (!mounted) return;
    final home = ref.read(homeSessionControllerProvider);
    if (!identical(home, _home) ||
        (_identity != null &&
            (home?.runtimeIdentity != _identity ||
                home?.account.generation != _accountGeneration))) {
      _retire();
    }
    setState(() {});
  }

  void _discoveryChanged() {
    if (mounted) setState(() {});
  }

  bool _visible() {
    if (!mounted || !_foreground || !TickerMode.valuesOf(context).enabled) {
      return false;
    }
    final home = ref.read(homeSessionControllerProvider);
    return home != null &&
        home.source == HomeSource.verifiedCore &&
        !home.busy &&
        home.failure == null &&
        home.interaction.active &&
        home.runtimeIdentity == _identity;
  }

  void _retire() {
    _operation++;
    _discovery?.removeListener(_discoveryChanged);
    _discovery?.dispose();
    _discoveryApi?.close();
    _discovery = null;
    _discoveryApi = null;
    _owner?.retire();
    _owner?.dispose();
    _owner = null;
    _target = null;
    _identity = null;
    _accountGeneration = -1;
    _loading = false;
    _attempted = false;
  }

  void _retry() {
    if (!mounted) return;
    _attempted = false;
    _failure = null;
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    final resourceId = widget.tile.entityId;
    if (_loading ||
        _target != null ||
        _attempted ||
        resourceId == null ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(resourceId)) {
      return;
    }
    final home = ref.read(homeSessionControllerProvider),
        operation = ++_operation;
    if (home == null ||
        home.source != HomeSource.verifiedCore ||
        home.busy ||
        home.failure != null ||
        !home.interaction.active ||
        home.account.session == null) {
      return;
    }
    final identity = home.runtimeIdentity,
        generation = home.account.generation,
        interactionEpoch = home.interaction.epoch;
    bool current() =>
        mounted &&
        operation == _operation &&
        identical(ref.read(homeSessionControllerProvider), home) &&
        home.runtimeIdentity == identity &&
        home.interaction.epoch == interactionEpoch &&
        home.account.isCurrent(generation) &&
        home.source == HomeSource.verifiedCore &&
        home.interaction.active &&
        _foreground;
    _identity = identity;
    _accountGeneration = generation;
    _attempted = true;
    setState(() {
      _loading = true;
      _failure = null;
    });
    LarenorServerApi? api;
    try {
      HomeResourceRecord? target;
      ServerSession? boundSession;
      await home.account.withSession((_, session) async {
        if (!current() || session.context == null) {
          throw const LarenorServerException('cancelled');
        }
        api = ref.read(coreProxmoxApiFactoryProvider)(session.endpoint);
        final raw = await api!.request(
          'GET',
          '/home-resources/${session.context!.coreId}/${session.context!.homeId}/$resourceId',
          token: session.accessToken,
        );
        if (!current() ||
            raw == null ||
            raw.length != 1 ||
            !raw.containsKey('record')) {
          throw const LarenorServerException('invalid_response');
        }
        target = HomeResourceRecord.fromJson(
          raw['record'],
          expectedContext: session.context!,
        );
        if (target!.id != resourceId ||
            target!.kind != HomeResourceKind.resource) {
          throw const LarenorServerException('invalid_response');
        }
        boundSession = session;
      });
      if (!current() || target == null) return;
      _target = target;
      _owner = CoreHaOwner(isCurrent: _visible, interaction: home.interaction);
      final session = boundSession;
      if (session?.user.canAdminister == true) {
        final discoveryApi = ref.read(coreProxmoxApiFactoryProvider)(
          session!.endpoint,
        );
        final discovery = ProxmoxTargetDiscoveryController(
          gateway: CoreProxmoxTargetDiscoveryApi(
            discoveryApi,
            session.accessToken,
          ),
          resource: target!,
          current: _visible,
        );
        _discoveryApi = discoveryApi;
        _discovery = discovery;
        discovery.addListener(_discoveryChanged);
        unawaited(discovery.discover());
      }
    } catch (error) {
      if (current()) {
        _failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      api?.close();
      if (mounted && operation == _operation) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _operation++;
    _lifecycle?.dispose();
    _home?.removeListener(_authorityChanged);
    _home?.account.removeListener(_authorityChanged);
    _home?.interaction.removeListener(_authorityChanged);
    _owner?.dispose();
    _discovery?.removeListener(_discoveryChanged);
    _discovery?.dispose();
    _discoveryApi?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), target = _target, owner = _owner;
    if (!_loading && !_attempted && target == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
    }
    if (target == null || owner == null || !owner.isCurrent) {
      return ServiceTileShell(
        icon: CupertinoIcons.square_stack_3d_up,
        service: AppService.proxmox,
        title: widget.tile.title ?? 'Proxmox',
        connected: true,
        evidence: _loading
            ? const ConnectionEvidence.connecting()
            : _failure == 'forbidden' || _failure == 'not_found'
            ? const ConnectionEvidence.permissionDenied()
            : _failure != null
            ? const ConnectionEvidence.unavailable()
            : const ConnectionEvidence.saved(),
        onTap: _retry,
        lines: [
          if (widget.tile.entityId == null)
            l.coreProxmoxChooseResource
          else if (_loading)
            l.commonLoading
          else if (_failure == 'forbidden' || _failure == 'not_found')
            l.coreProxmoxPermission
          else if (_failure != null)
            l.coreProxmoxOffline
          else
            l.coreProxmoxRequired,
        ],
      );
    }
    final selection = (owner: owner, target: target, admin: false);
    final controller = ref.watch(coreProxmoxControllerProvider(selection));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && owner.isCurrent) controller.setVisible(true);
    });
    return ListenableBuilder(
      listenable: controller,
      builder: (_, _) {
        final snapshot = controller.snapshot;
        final summary = snapshot?.summary;
        final session = _home?.account.session;
        final admin = session?.user.canAdminister == true;
        final discovery = _discovery;
        final commandTarget = discovery?.target;
        final tr = Localizations.localeOf(context).languageCode == 'tr';
        String percent(double value) => '${(value * 100).round()}%';
        String uptime(Duration value) {
          if (value.inDays > 0) return '${value.inDays}d';
          if (value.inHours > 0) return '${value.inHours}h';
          return '${value.inMinutes}m';
        }

        T? firstWhereOrNull<T>(Iterable<T> values, bool Function(T) match) {
          for (final value in values) {
            if (match(value)) return value;
          }
          return null;
        }

        final exactNode = summary == null || commandTarget == null
            ? null
            : firstWhereOrNull(
                summary.nodes,
                (value) => value.name == commandTarget.node,
              );
        final node = exactNode ?? summary?.nodes.firstOrNull;
        final exactGuest = summary == null || commandTarget == null
            ? null
            : firstWhereOrNull(
                summary.guests,
                (value) =>
                    value.node == commandTarget.node &&
                    value.vmId == commandTarget.guestId &&
                    value.kind.name == commandTarget.guestKind.name,
              );
        final guest = exactGuest ?? summary?.guests.firstOrNull;
        final storage = summary == null || node == null
            ? null
            : firstWhereOrNull(
                summary.storages,
                (value) => value.node == node.name && value.active,
              );
        final exactState =
            exactGuest != null &&
            commandTarget != null &&
            switch (commandTarget.currentState) {
              ProxmoxGuestState.running =>
                exactGuest.status == CoreProxmoxGuestStatus.running,
              ProxmoxGuestState.stopped =>
                exactGuest.status == CoreProxmoxGuestStatus.stopped,
              ProxmoxGuestState.suspended => false,
            };
        final coherent =
            snapshot != null &&
            commandTarget != null &&
            exactNode != null &&
            exactState &&
            snapshot.bindingId == commandTarget.bindingId &&
            snapshot.bindingRevision == commandTarget.bindingRevision &&
            snapshot.serviceId == commandTarget.serviceId &&
            snapshot.serviceRevision == commandTarget.serviceRevision &&
            snapshot.resourceRevision == commandTarget.resourceRevision &&
            snapshot.aclRevision == commandTarget.aclRevision;
        final readiness = !admin
            ? (tr ? 'Salt okunur özet' : 'Read-only summary')
            : switch (discovery?.phase) {
                ProxmoxTargetDiscoveryPhase.loading =>
                  tr ? 'Güç hedefi doğrulanıyor' : 'Verifying power target',
                ProxmoxTargetDiscoveryPhase.ready when !coherent =>
                  tr
                      ? 'Özet ve hedef değişti; yenile'
                      : 'Summary and target changed; refresh',
                ProxmoxTargetDiscoveryPhase.ready when target.canWrite =>
                  tr ? 'Güç komutları hazır' : 'Power commands ready',
                ProxmoxTargetDiscoveryPhase.ready =>
                  tr ? 'Salt okunur özet' : 'Read-only summary',
                ProxmoxTargetDiscoveryPhase.ambiguous =>
                  tr
                      ? 'Birden fazla konuk; komutlar kapalı'
                      : 'Multiple guests; commands disabled',
                ProxmoxTargetDiscoveryPhase.stale =>
                  tr ? 'Hedef değişti; yenile' : 'Target changed; refresh',
                ProxmoxTargetDiscoveryPhase.offline =>
                  tr
                      ? 'Proxmox çevrimdışı; yenile'
                      : 'Proxmox offline; refresh',
                ProxmoxTargetDiscoveryPhase.unavailable =>
                  tr ? 'Komuta hazır hedef yok' : 'No command-ready target',
                ProxmoxTargetDiscoveryPhase.forbidden =>
                  tr
                      ? 'Yönetici yetkisi gerekli'
                      : 'Administrator access required',
                ProxmoxTargetDiscoveryPhase.invalid =>
                  tr
                      ? 'Hedef doğrulanamadı; yenile'
                      : 'Target could not be verified; refresh',
                _ => tr ? 'Güç hedefini yenile' : 'Refresh power target',
              };
        final lines = <String>[
          if (controller.busy)
            l.commonLoading
          else if (controller.stale)
            l.coreProxmoxStale
          else if (controller.failure == 'forbidden' ||
              controller.failure == 'not_found')
            l.coreProxmoxPermission
          else if (controller.failure != null)
            l.coreProxmoxOffline
          else if (summary == null)
            l.coreProxmoxRequired
          else ...[
            if (node != null)
              '${node.name} · ${node.status == CoreProxmoxNodeStatus.online ? l.coreProxmoxOnline : l.coreProxmoxOfflineState} · ${tr ? 'Çalışma süresi' : 'Uptime'} ${uptime(node.uptime)}',
            if (node != null)
              'CPU ${percent(node.cpuRatio)} · RAM ${percent(node.memoryUsedBytes / node.memoryTotalBytes)}${storage == null ? '' : ' · ${tr ? 'Depolama' : 'Storage'} ${percent(storage.usedRatio)}'}',
            if (guest != null)
              '${guest.kind == CoreProxmoxGuestKind.qemu ? 'QEMU' : 'LXC'} #${guest.vmId} · ${guest.status == CoreProxmoxGuestStatus.running ? (tr ? 'Çalışıyor' : 'Running') : (tr ? 'Durduruldu' : 'Stopped')} · $readiness'
            else
              readiness,
          ],
        ];
        void openDetail() => Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => CoreProxmoxScreen(
              target: target,
              onOpenPowerControls: (detailContext, powerTarget, canWrite) {
                Navigator.of(detailContext).push<void>(
                  CupertinoPageRoute(
                    builder: (_) => SettingsGateScreen(
                      initialDestination: SettingsGateDestination.proxmoxPower,
                      proxmoxPowerTarget: powerTarget,
                      proxmoxCanWrite: canWrite,
                    ),
                  ),
                );
              },
            ),
          ),
        );
        VoidCallback? onTap;
        if (summary == null || controller.stale || controller.failure != null) {
          onTap = controller.busy
              ? null
              : () {
                  discovery?.invalidate();
                  unawaited(controller.refresh());
                };
        } else {
          onTap = openDetail;
        }
        return ServiceTileShell(
          icon: CupertinoIcons.square_stack_3d_up,
          service: AppService.proxmox,
          title: widget.tile.title ?? 'Proxmox',
          connected: true,
          evidence: controller.busy
              ? const ConnectionEvidence.connecting()
              : controller.stale
              ? const ConnectionEvidence.stale()
              : controller.failure == 'forbidden' ||
                    controller.failure == 'not_found'
              ? const ConnectionEvidence.permissionDenied()
              : controller.failure != null
              ? const ConnectionEvidence.unavailable()
              : snapshot != null
              ? ConnectionEvidence.verified(snapshot.observedAt)
              : const ConnectionEvidence.saved(),
          onTap: owner.isCurrent ? onTap : null,
          lines: lines,
        );
      },
    );
  }
}
