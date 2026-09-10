import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/home_session_controller.dart';
import '../../../../core/home_source_store.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../core_ha/data/core_ha_providers.dart';
import '../../../core_proxmox/data/core_proxmox_providers.dart';
import '../../../core_proxmox/domain/core_proxmox_models.dart';
import '../../../core_proxmox/presentation/core_proxmox_screen.dart';
import '../../../home_resources/domain/home_resource_models.dart';
import '../../../server/data/larenor_server_api.dart';
import '../../../server/domain/server_models.dart';
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
      connected: configured || config.isLoading || config.hasError,
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
  Object? _identity;
  int _operation = 0;
  bool _foreground = true, _loading = false;
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
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
    _owner?.retire();
    _owner?.dispose();
    _owner = null;
    _target = null;
    _identity = null;
    _loading = false;
  }

  Future<void> _resolve() async {
    final resourceId = widget.tile.entityId;
    if (_loading ||
        _target != null ||
        resourceId == null ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(resourceId)) {
      return;
    }
    final home = ref.read(homeSessionControllerProvider),
        operation = ++_operation;
    if (home == null || home.source != HomeSource.verifiedCore) return;
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
    setState(() {
      _loading = true;
      _failure = null;
    });
    LarenorServerApi? api;
    try {
      HomeResourceRecord? target;
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
      });
      if (!current() || target == null) return;
      _target = target;
      _owner = CoreHaOwner(isCurrent: _visible, interaction: home.interaction);
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
    _owner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), target = _target, owner = _owner;
    if (!_loading && target == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
    }
    if (target == null || owner == null || !owner.isCurrent) {
      return ServiceTileShell(
        icon: CupertinoIcons.square_stack_3d_up,
        service: AppService.proxmox,
        title: widget.tile.title ?? 'Proxmox',
        connected: true,
        onTap: _resolve,
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
        final summary = controller.snapshot?.summary;
        String percent(double value) => '${(value * 100).round()}%';
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
            '${l.coreProxmoxNode}: ${summary.nodes.length} · ${l.coreProxmoxVm}/${l.coreProxmoxContainer}: ${summary.guests.length}',
            for (final node in summary.nodes.take(2))
              '${node.name} · ${node.status == CoreProxmoxNodeStatus.online ? l.coreProxmoxOnline : l.coreProxmoxOfflineState} · CPU ${percent(node.cpuRatio)}',
          ],
        ];
        return ServiceTileShell(
          icon: CupertinoIcons.square_stack_3d_up,
          service: AppService.proxmox,
          title: widget.tile.title ?? 'Proxmox',
          connected: true,
          onTap: summary == null || !owner.isCurrent
              ? () => unawaited(controller.refresh())
              : () => Navigator.of(context).push(
                  CupertinoPageRoute<void>(
                    builder: (_) => CoreProxmoxScreen(target: target),
                  ),
                ),
          lines: lines,
        );
      },
    );
  }
}
