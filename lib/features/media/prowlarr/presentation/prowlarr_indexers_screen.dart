import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/direct_home_access.dart';
import '../providers/prowlarr_providers.dart';
import 'prowlarr_connect_screen.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/theme/spacing.dart';

class ProwlarrIndexersScreen extends ConsumerWidget {
  const ProwlarrIndexersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(prowlarrConnectionProvider);

    return connectionAsync.when(
      skipLoadingOnReload: false,
      skipLoadingOnRefresh: false,
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) {
        if (error is DirectHomeAccessException &&
            error.code == 'pending_mutation') {
          return const ProwlarrConnectScreen();
        }
        return CupertinoPageScaffold(
          child: Center(
            child: Text(AppLocalizations.of(context).mediaErrorUnreachable),
          ),
        );
      },
      data: (config) {
        if (config == null) return const ProwlarrConnectScreen();
        return const _IndexersList();
      },
    );
  }
}

class _IndexersList extends ConsumerWidget {
  const _IndexersList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final indexersAsync = ref.watch(prowlarrIndexersProvider);
    final client = ref.watch(prowlarrClientProvider);

    return ServiceRootScaffold(
      title: 'Prowlarr',
      leading: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () => ref.invalidate(prowlarrIndexersProvider),
        child: const Icon(CupertinoIcons.refresh),
      ),
      slivers: indexersAsync.when(
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
        data: (indexers) {
          if (indexers.isEmpty) {
            return [
              SliverFilledMessage(
                child: Text(
                  AppLocalizations.of(context).prowlarrNoIndexersConfigured,
                ),
              ),
            ];
          }
          return [
            SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: Gap.sm),
                CupertinoListSection.insetGrouped(
                  children: [
                    for (final indexer in indexers)
                      CupertinoListTile(
                        title: Text(indexer.name),
                        subtitle: Text(
                          '${indexer.protocol} · priority ${indexer.priority}',
                        ),
                        trailing: CupertinoSwitch(
                          value: indexer.enabled,
                          onChanged: client == null
                              ? null
                              : (value) async {
                                  await client.setIndexerEnabled(
                                    indexer,
                                    value,
                                  );
                                  ref.invalidate(prowlarrIndexersProvider);
                                },
                        ),
                      ),
                  ],
                ),
              ]),
            ),
          ];
        },
      ),
    );
  }
}
