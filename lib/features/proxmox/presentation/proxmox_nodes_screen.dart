import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/proxmox_node.dart';
import '../providers/proxmox_providers.dart';
import 'proxmox_connect_screen.dart';
import 'proxmox_node_detail_screen.dart';
import 'proxmox_session_guard.dart';
import 'widgets/proxmox_usage_bar.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/operational_service_scope.dart';
import '../../health/data/health_configuration.dart';

class ProxmoxNodesScreen extends ConsumerStatefulWidget {
  const ProxmoxNodesScreen({super.key});

  @override
  ConsumerState<ProxmoxNodesScreen> createState() => _ProxmoxNodesScreenState();
}

class _ProxmoxNodesScreenState extends ConsumerState<ProxmoxNodesScreen> {
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
    final connectionAsync = ref.watch(proxmoxConnectionProvider);
    if (!_foreground || !TickerMode.valuesOf(context).enabled) {
      return const SizedBox.shrink();
    }

    return connectionAsync.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) => CupertinoPageScaffold(
        child: Center(
          child: Text(AppLocalizations.of(context).healthReadError),
        ),
      ),
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
    final account = ref.watch(proxmoxConnectionProvider);

    return ServiceRootScaffold(
      title: 'Proxmox VE',
      leading: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () => ref.invalidate(proxmoxNodesProvider),
        child: const Icon(CupertinoIcons.refresh),
      ),
      trailing: ServiceAccountAction(
        onSignOut: () async {
          if (!context.mounted) return;
          final current = ref.read(proxmoxConnectionProvider);
          if (current.isLoading ||
              current.hasError ||
              !sameHealthConfiguration(account.value, current.value)) {
            return;
          }
          await ref.read(proxmoxConnectionProvider.notifier).signOut();
        },
      ),
      slivers: nodesAsync.when(
        skipLoadingOnRefresh: false,
        skipLoadingOnReload: false,
        loading: () => const [
          SliverFilledMessage(child: CupertinoActivityIndicator()),
        ],
        error: (error, _) => [
          SliverFilledMessage(
            child: Text(AppLocalizations.of(context).healthReadError),
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
            SliverPadding(
              padding: const EdgeInsets.all(20),
              sliver: SliverList.builder(
                itemCount: nodes.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: CupertinoColors.secondarySystemGroupedBackground
                          .resolveFrom(context),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: _NodeRow(
                      key: ValueKey(nodes[index].name),
                      node: nodes[index],
                    ),
                  ),
                ),
              ),
            ),
          ];
        },
      ),
    );
  }
}

class _NodeRow extends ConsumerWidget {
  const _NodeRow({super.key, required this.node});

  final ProxmoxNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(proxmoxConnectionProvider);
    return CupertinoListTile(
      leading: Icon(
        node.isOnline
            ? CupertinoIcons.checkmark_seal_fill
            : node.status == 'offline'
            ? CupertinoIcons.xmark_seal_fill
            : CupertinoIcons.question_circle,
        color: node.isOnline
            ? CupertinoColors.systemGreen.resolveFrom(context)
            : node.status == 'offline'
            ? CupertinoColors.systemRed.resolveFrom(context)
            : CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
      title: Text(node.name),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            Expanded(
              child: ProxmoxUsageBar(
                label: 'CPU',
                fraction: node.isOnline ? node.cpuFraction : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ProxmoxUsageBar(
                label: 'RAM',
                fraction: node.isOnline ? node.memFraction : null,
              ),
            ),
          ],
        ),
      ),
      trailing: const CupertinoListTileChevron(),
      onTap: () {
        final current = ref.read(proxmoxConnectionProvider);
        if (!context.mounted ||
            current.isLoading ||
            current.hasError ||
            current.value == null ||
            !sameHealthConfiguration(account.value, current.value)) {
          return;
        }
        final source = captureProxmoxRouteSource(ref);
        if (source == null) return;
        Navigator.of(context).push(
          CupertinoPageRoute(
            builder: (_) => ProxmoxNodeDetailScreen(
              nodeName: node.name,
              sourceCurrent: source,
            ),
          ),
        );
      },
    );
  }
}
