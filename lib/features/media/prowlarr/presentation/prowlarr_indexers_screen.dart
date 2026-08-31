import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/prowlarr_providers.dart';
import 'prowlarr_connect_screen.dart';

class ProwlarrIndexersScreen extends ConsumerWidget {
  const ProwlarrIndexersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(prowlarrConnectionProvider);

    return connectionAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) =>
          CupertinoPageScaffold(child: Center(child: Text('$error'))),
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

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Prowlarr'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => ref.invalidate(prowlarrIndexersProvider),
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: indexersAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (indexers) {
            if (indexers.isEmpty) {
              return const Center(child: Text('No indexers configured'));
            }
            return ListView(
              children: [
                const SizedBox(height: 16),
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
              ],
            );
          },
        ),
      ),
    );
  }
}
