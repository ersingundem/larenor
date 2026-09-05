import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
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
