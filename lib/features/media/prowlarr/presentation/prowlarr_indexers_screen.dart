import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/direct_home_access.dart';
import '../../../health/data/integration_health.dart';
import '../../hub/presentation/media_session_state.dart';
import '../data/models/prowlarr_indexer.dart';
import '../data/prowlarr_client.dart';
import '../providers/prowlarr_providers.dart';
import 'prowlarr_connect_screen.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/service_route_status_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../../shared/theme/spacing.dart';

class ProwlarrIndexersScreen extends ConsumerWidget {
  const ProwlarrIndexersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(prowlarrConnectionProvider);

    return connectionAsync.when(
      skipLoadingOnReload: false,
      skipLoadingOnRefresh: false,
      loading: () => ServiceRouteStatusScaffold(
        title: 'Prowlarr',
        label: AppLocalizations.of(context).commonLoading,
        statusKey: const ValueKey('prowlarr-indexers-status'),
        loading: true,
      ),
      error: (error, _) {
        if (error is DirectHomeAccessException &&
            const {
              'pending_mutation',
              'write_unconfirmed',
            }.contains(error.code)) {
          return const ProwlarrConnectScreen();
        }
        return ServiceRouteStatusScaffold(
          title: 'Prowlarr',
          label: AppLocalizations.of(context).mediaErrorUnreachable,
          statusKey: const ValueKey('prowlarr-indexers-status'),
          actionLabel: AppLocalizations.of(context).commonRetry,
          actionKey: const ValueKey('prowlarr-indexers-retry'),
          onAction: () => ref.invalidate(prowlarrConnectionProvider),
        );
      },
      data: (config) {
        if (config == null) return const ProwlarrConnectScreen();
        return const _IndexersList();
      },
    );
  }
}

class _IndexersList extends ConsumerStatefulWidget {
  const _IndexersList();

  @override
  ConsumerState<_IndexersList> createState() => _IndexersListState();
}

class _IndexersListState extends MediaSessionState<_IndexersList> {
  final _pending = <int>{};
  String? _error;

  bool _current(int generation, ProwlarrClient client, Object reading) =>
      sessionCurrent(generation) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true &&
      identical(ref.read(prowlarrClientProvider), client) &&
      identical(ref.read(prowlarrIndexersProvider), reading);

  Future<void> _toggle(
    ProwlarrIndexer indexer,
    bool value,
    ProwlarrClient client,
    Object reading,
    int generation,
  ) async {
    if (_pending.contains(indexer.id) ||
        !_current(generation, client, reading)) {
      return;
    }
    setState(() {
      _pending.add(indexer.id);
      _error = null;
    });
    try {
      await client.setIndexerEnabled(indexer, value);
      if (_current(generation, client, reading)) {
        ref.invalidate(prowlarrIndexersProvider);
      }
    } catch (_) {
      if (_current(generation, client, reading)) {
        setState(() => _error = AppLocalizations.of(context).actionFailed);
      }
    } finally {
      if (_current(generation, client, reading)) {
        setState(() => _pending.remove(indexer.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    watchMediaAccount(IntegrationId.prowlarr, prowlarrConnectionProvider);
    final indexersAsync = ref.watch(prowlarrIndexersProvider);
    final client = ref.watch(prowlarrClientProvider);
    final l10n = AppLocalizations.of(context);
    final generation = sessionGeneration;

    return ServiceRootScaffold(
      title: 'Prowlarr',
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              key: const ValueKey('prowlarr-indexers-section-title'),
              container: true,
              header: true,
              child: const Text('Prowlarr'),
            ),
            children: [
              if (_error != null)
                Padding(padding: Insets.tile, child: Text(_error!)),
              SettingsActionTile(
                buttonKey: const ValueKey('prowlarr-indexers-refresh'),
                leading: const Icon(CupertinoIcons.refresh),
                title: Text(l10n.commonRefresh),
                onTap:
                    client != null &&
                        _current(generation, client, indexersAsync)
                    ? () {
                        if (_current(generation, client, indexersAsync)) {
                          ref.invalidate(prowlarrIndexersProvider);
                        }
                      }
                    : null,
              ),
            ],
          ),
        ),
        ...indexersAsync.when(
          loading: () => const [
            SliverFilledMessage(child: CupertinoActivityIndicator()),
          ],
          error: (error, _) => [
            SliverFilledMessage(
              child: Text(l10n.adminLoadError(l10n.actionFailed)),
            ),
          ],
          data: (indexers) {
            if (indexers.isEmpty) {
              return [
                SliverFilledMessage(
                  child: Text(l10n.prowlarrNoIndexersConfigured),
                ),
              ];
            }
            return [
              SliverPadding(
                padding: Insets.page,
                sliver: SliverList.builder(
                  itemCount: indexers.length,
                  itemBuilder: (context, index) {
                    final indexer = indexers[index];
                    final toggle =
                        client == null || _pending.contains(indexer.id)
                        ? null
                        : (bool value) => _toggle(
                            indexer,
                            value,
                            client,
                            indexersAsync,
                            generation,
                          );
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Gap.sm),
                      child: SettingsSection(
                        margin: EdgeInsets.zero,
                        children: [
                          CupertinoListTile(
                            title: Text(indexer.name),
                            subtitle: Text(
                              l10n.prowlarrIndexerSubtitle(
                                indexer.protocol,
                                indexer.priority,
                              ),
                            ),
                            trailing: Semantics(
                              key: ValueKey(
                                'prowlarr-indexer-${indexer.id}-toggle',
                              ),
                              container: true,
                              label: indexer.name,
                              toggled: indexer.enabled,
                              enabled: toggle != null,
                              onTap: toggle == null
                                  ? null
                                  : () => toggle(!indexer.enabled),
                              child: SizedBox(
                                width: 60,
                                height: 48,
                                child: Center(
                                  child: ExcludeSemantics(
                                    child: CupertinoSwitch(
                                      value: indexer.enabled,
                                      onChanged: toggle,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ];
          },
        ),
      ],
    );
  }
}
