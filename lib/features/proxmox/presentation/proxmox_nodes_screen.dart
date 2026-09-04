import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/proxmox_node.dart';
import '../providers/proxmox_providers.dart';
import 'proxmox_connect_screen.dart';
import 'proxmox_node_detail_screen.dart';
import 'widgets/proxmox_usage_bar.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/operational_service_scope.dart';
import '../../../shared/theme/spacing.dart';

class ProxmoxNodesScreen extends ConsumerWidget {
  const ProxmoxNodesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(proxmoxConnectionProvider);

    return connectionAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) =>
          CupertinoPageScaffold(child: Center(child: Text(error.toString()))),
      data: (config) {
        if (config == null) return const ProxmoxConnectScreen();
        return const _NodesList();
      },
    );
  }
}

class _NodesList extends ConsumerWidget {
  const _NodesList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodesAsync = ref.watch(proxmoxNodesProvider);

    return ServiceRootScaffold(
      title: 'Proxmox VE',
      leading: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () => ref.invalidate(proxmoxNodesProvider),
        child: const Icon(CupertinoIcons.refresh),
      ),
      trailing: ServiceAccountAction(
        onSignOut: () => ref.read(proxmoxConnectionProvider.notifier).signOut(),
      ),
      slivers: nodesAsync.when(
        loading: () => const [
          SliverFilledMessage(child: CupertinoActivityIndicator()),
        ],
        error: (error, _) => [
          SliverFilledMessage(
            child: Text(
              AppLocalizations.of(context).adminLoadError(error.toString()),
            ),
          ),
        ],
        data: (nodes) {
          if (nodes.isEmpty) {
            return [
              SliverFilledMessage(
                child: Text(AppLocalizations.of(context).proxmoxTileNoNodes),
              ),
            ];
          }
          return [
            SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: Gap.sm),
                CupertinoListSection.insetGrouped(
                  children: [for (final node in nodes) _NodeRow(node: node)],
                ),
              ]),
            ),
          ];
        },
      ),
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({required this.node});

  final ProxmoxNode node;

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      leading: Icon(
        node.isOnline
            ? CupertinoIcons.checkmark_seal_fill
            : CupertinoIcons.xmark_seal_fill,
        color: node.isOnline
            ? CupertinoColors.systemGreen.resolveFrom(context)
            : CupertinoColors.systemRed.resolveFrom(context),
      ),
      title: Text(node.name),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            Expanded(
              child: ProxmoxUsageBar(label: 'CPU', fraction: node.cpuFraction),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ProxmoxUsageBar(label: 'RAM', fraction: node.memFraction),
            ),
          ],
        ),
      ),
      trailing: const CupertinoListTileChevron(),
      onTap: () => Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (_) => ProxmoxNodeDetailScreen(nodeName: node.name),
        ),
      ),
    );
  }
}
