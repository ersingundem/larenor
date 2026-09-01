import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../proxmox/presentation/proxmox_nodes_screen.dart';
import '../../../proxmox/providers/proxmox_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';
import '../../../settings/data/app_service.dart';

class ProxmoxTile extends ConsumerWidget {
  const ProxmoxTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(proxmoxConnectionProvider).value != null;
    final nodes = ref.watch(proxmoxNodesProvider).value ?? const [];

    return ServiceTileShell(
      icon: CupertinoIcons.square_stack_3d_up,
      service: AppService.proxmox,
      title: 'Proxmox',
      connected: connected,
      onTap: () => Navigator.of(context)
          .push(CupertinoPageRoute(builder: (_) => const ProxmoxNodesScreen())),
      lines: nodes.isEmpty
          ? [AppLocalizations.of(context).proxmoxTileNoNodes]
          : nodes
                .take(3)
                .map(
                  (n) => AppLocalizations.of(context).proxmoxTileNodeStats(
                    n.name,
                    ((n.cpuFraction ?? 0) * 100).round(),
                    ((n.memFraction ?? 0) * 100).round(),
                  ),
                )
                .toList(),
    );
  }
}
