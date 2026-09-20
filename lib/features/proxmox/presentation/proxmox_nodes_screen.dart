import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/spacing.dart';
import '../../../core/direct_home_access.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../data/models/proxmox_node.dart';
import '../providers/proxmox_providers.dart';
import 'proxmox_connect_screen.dart';
import 'proxmox_node_detail_screen.dart';
import 'proxmox_session_guard.dart';
import 'widgets/proxmox_usage_bar.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/operational_service_scope.dart';
import '../../health/data/health_configuration.dart';

class ProxmoxNodesScreen extends ConsumerStatefulWidget {
  const ProxmoxNodesScreen({super.key});

  @override
  ConsumerState<ProxmoxNodesScreen> createState() => _ProxmoxNodesScreenState();
}

class _ProxmoxNodesScreenState extends MediaSessionState<ProxmoxNodesScreen>
    with WidgetsBindingObserver {
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  bool _visible = true;
  int? _viewId;
  bool _focused = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  bool _current(int generation) =>
      sessionCurrent(generation) &&
      _focused &&
      _access.isCurrent &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final viewId = View.of(context).viewId;
    if (_viewId != null && _viewId != viewId) sessionGeneration++;
    _viewId = viewId;
    final visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (_visible && !visible) sessionGeneration++;
    _visible = visible;
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (!mounted || event.viewId != _viewId) return;
    final focused = event.state == ViewFocusState.focused;
    if (_focused == focused) return;
    setState(() {
      _focused = focused;
      if (!focused) sessionGeneration++;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(directHomeAccessProvider);
    final connectionAsync = ref.watch(proxmoxConnectionProvider);
    if (!_access.isCurrent ||
        !foreground ||
        !TickerMode.valuesOf(context).enabled) {
      return const SizedBox.shrink();
    }
    final generation = sessionGeneration;
    final error = connectionAsync.error;
    final recovery =
        error is DirectHomeAccessException &&
        {'pending_mutation', 'write_unconfirmed'}.contains(error.code);
    if (!connectionAsync.isLoading &&
        OperationalServiceScope.maybeOf(context) == null &&
        (recovery ||
            !connectionAsync.hasError && connectionAsync.value == null)) {
      return ProxmoxConnectScreen(
        key: ValueKey(recovery),
        recovery: recovery,
        popOnSuccess: false,
      );
    }
    return connectionAsync.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (_, _) => CupertinoPageScaffold(
        child: Center(
          child: Text(AppLocalizations.of(context).healthReadError),
        ),
      ),
      data: (config) => config == null
          ? CupertinoPageScaffold(
              child: Center(
                child: Text(AppLocalizations.of(context).healthReadError),
              ),
            )
          : _NodesList(current: () => _current(generation)),
    );
  }
}

class _NodesList extends ConsumerWidget {
  const _NodesList({required this.current});
  final bool Function() current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodesAsync = ref.watch(proxmoxNodesProvider);
    final account = ref.watch(proxmoxConnectionProvider);
    final l10n = AppLocalizations.of(context);
    final operational = OperationalServiceScope.isOperational(context);

    return ServiceRootScaffold(
      title: 'Proxmox VE',
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              key: const ValueKey('proxmox-nodes-section-title'),
              container: true,
              header: true,
              child: const Text('Proxmox VE'),
            ),
            children: [
              SettingsActionTile(
                buttonKey: const ValueKey('proxmox-nodes-refresh'),
                leading: const Icon(CupertinoIcons.refresh),
                title: Text(l10n.commonRefresh),
                onTap: () {
                  if (context.mounted && current()) {
                    ref.invalidate(proxmoxNodesProvider);
                  }
                },
              ),
              SettingsActionTile(
                buttonKey: const ValueKey('service-account-action'),
                leading: Icon(
                  operational
                      ? CupertinoIcons.settings
                      : CupertinoIcons.square_arrow_right,
                ),
                title: Text(
                  operational ? l10n.settingsScreenTitle : l10n.commonSignOut,
                ),
                onTap: operational
                    ? () => context.push('/settings')
                    : () async {
                        if (!context.mounted || !current()) return;
                        final accountNow = ref.read(proxmoxConnectionProvider);
                        if (accountNow.isLoading ||
                            accountNow.hasError ||
                            !sameHealthConfiguration(
                              account.value,
                              accountNow.value,
                            )) {
                          return;
                        }
                        await ref
                            .read(proxmoxConnectionProvider.notifier)
                            .signOut(isCurrent: current);
                      },
              ),
            ],
          ),
        ),
        ...nodesAsync.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          loading: () => const [
            SliverFilledMessage(child: CupertinoActivityIndicator()),
          ],
          error: (error, _) => [
            SliverFilledMessage(child: Text(l10n.healthReadError)),
          ],
          data: (nodes) {
            if (nodes.isEmpty) {
              return [
                SliverFilledMessage(child: Text(l10n.proxmoxTileNoNodes)),
              ];
            }
            return [
              SliverPadding(
                padding: Insets.page,
                sliver: SliverList.builder(
                  itemCount: nodes.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: Gap.sm),
                    child: SettingsSection(
                      margin: EdgeInsets.zero,
                      children: [
                        _NodeRow(
                          key: ValueKey(
                            'proxmox-node-${nodes[index].name}-row',
                          ),
                          node: nodes[index],
                          current: current,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ];
          },
        ),
      ],
    );
  }
}

class _NodeRow extends ConsumerWidget {
  const _NodeRow({super.key, required this.node, required this.current});
  final bool Function() current;

  final ProxmoxNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(proxmoxConnectionProvider);
    return SettingsActionTile(
      buttonKey: ValueKey('proxmox-node-${node.name}'),
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
      additionalInfo: Row(
        children: [
          Expanded(
            child: ProxmoxUsageBar(
              label: 'CPU',
              fraction: node.isOnline ? node.cpuFraction : null,
            ),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: ProxmoxUsageBar(
              label: 'RAM',
              fraction: node.isOnline ? node.memFraction : null,
            ),
          ),
        ],
      ),
      onTap: () {
        if (!context.mounted || !current()) return;
        final accountNow = ref.read(proxmoxConnectionProvider);
        if (!context.mounted ||
            accountNow.isLoading ||
            accountNow.hasError ||
            accountNow.value == null ||
            !sameHealthConfiguration(account.value, accountNow.value)) {
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
