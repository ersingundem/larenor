import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/direct_home_access.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/integration_health_status.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/service_route_status_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../health/data/integration_health.dart';
import '../providers/keenetic_providers.dart';
import 'keenetic_session_guard.dart';

class KeeneticPortForwardingScreen extends ConsumerWidget {
  const KeeneticPortForwardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    if (!ref.watch(directHomeAccessProvider).isCurrent) {
      return ServiceRouteStatusScaffold(
        title: 'Keenetic',
        label: l10n.commonNotConnected,
        statusKey: const ValueKey('keenetic-ports-unavailable'),
      );
    }
    final connectionAsync = ref.watch(keeneticConnectionProvider);

    return connectionAsync.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      skipError: false,
      loading: () => ServiceRouteStatusScaffold(
        title: l10n.keeneticPortForwarding,
        label: l10n.commonLoading,
        statusKey: const ValueKey('keenetic-ports-loading'),
        loading: true,
      ),
      error: (error, _) => ServiceRouteStatusScaffold(
        title: l10n.keeneticPortForwarding,
        label: l10n.healthReadError,
        statusKey: const ValueKey('keenetic-ports-error'),
      ),
      data: (config) {
        if (config == null) {
          return ServiceRouteStatusScaffold(
            title: l10n.keeneticPortForwarding,
            label: l10n.navigationUnconfigured,
            statusKey: const ValueKey('keenetic-ports-unconfigured'),
          );
        }
        return const _RulesList();
      },
    );
  }
}

class _RulesList extends ConsumerStatefulWidget {
  const _RulesList();
  @override
  ConsumerState<_RulesList> createState() => _RulesListState();
}

class _RulesListState extends KeeneticSessionState<_RulesList> {
  @override
  Widget build(BuildContext context) {
    watchKeeneticSession();
    final generation = sessionGeneration;
    if (!keeneticAvailable) {
      final l10n = AppLocalizations.of(context);
      return ServiceRouteStatusScaffold(
        title: l10n.keeneticPortForwarding,
        label: l10n.commonNotConnected,
        statusKey: const ValueKey('keenetic-ports-unavailable'),
      );
    }
    final rulesAsync = ref.watch(keeneticPortForwardingProvider);

    final l10n = AppLocalizations.of(context);
    void refresh() {
      if (!keeneticCurrent(generation)) return;
      if (ref.read(keeneticClientProvider).hasError) {
        ref.invalidate(keeneticClientProvider);
      }
      ref.invalidate(keeneticPortForwardingProvider);
    }

    return rulesAsync.when(
      loading: () => ServiceRouteStatusScaffold(
        title: l10n.keeneticPortForwarding,
        label: l10n.commonLoading,
        statusKey: const ValueKey('keenetic-ports-loading'),
        loading: true,
      ),
      error: (error, _) => ServiceRouteStatusScaffold(
        title: l10n.keeneticPortForwarding,
        label: l10n.healthReadError,
        statusKey: const ValueKey('keenetic-ports-error'),
        actionLabel: l10n.commonRetry,
        actionKey: const ValueKey('keenetic-ports-refresh'),
        onAction: refresh,
      ),
      data: (rules) {
        if (rules.isEmpty) {
          return ServiceRouteStatusScaffold(
            title: l10n.keeneticPortForwarding,
            label: l10n.keeneticNoForwardingRules,
            statusKey: const ValueKey('keenetic-ports-empty'),
            actionLabel: l10n.commonRefresh,
            actionKey: const ValueKey('keenetic-ports-refresh'),
            onAction: refresh,
          );
        }
        return ServiceRootScaffold(
          title: l10n.keeneticPortForwarding,
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: refresh,
              child: Icon(
                CupertinoIcons.refresh,
                semanticLabel: l10n.commonRefresh,
              ),
            ),
          ),
          slivers: [
            SliverToBoxAdapter(
              child: SettingsSection(
                header: Semantics(
                  key: const ValueKey('keenetic-ports-heading'),
                  container: true,
                  header: true,
                  child: Text(l10n.keeneticPortForwarding),
                ),
                footer: Text(l10n.keeneticReadOnlyHint),
                children: [
                  const CupertinoListTile(
                    title: IntegrationHealthStatus(
                      id: IntegrationId.keenetic,
                      configured: true,
                    ),
                  ),
                  SettingsActionTile(
                    buttonKey: const ValueKey('keenetic-ports-refresh'),
                    leading: const Icon(CupertinoIcons.refresh),
                    title: Text(l10n.commonRefresh),
                    onTap: refresh,
                  ),
                  for (final rule in rules)
                    CupertinoListTile(
                      leading: const Icon(
                        CupertinoIcons.arrow_right_arrow_left,
                      ),
                      title: Text(rule.label),
                      subtitle: rule.destination != null
                          ? Text(
                              '${rule.protocol.toUpperCase()}${rule.portRange == null ? '' : ' ${rule.portRange}'} → ${rule.destination}',
                            )
                          : null,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
