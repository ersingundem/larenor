import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/icon_badge.dart';
import '../data/models/config_entry.dart';
import '../providers/admin_providers.dart';
import 'add_integration_screen.dart';

class IntegrationsScreen extends ConsumerWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(configEntriesProvider);

    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: const Text('Integrations'),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () =>
                  ref.read(configEntriesProvider.notifier).refresh(),
              child: const Icon(CupertinoIcons.refresh),
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.of(context).push(
                CupertinoPageRoute(
                  builder: (_) => const AddIntegrationScreen(),
                ),
              ),
              child: const Icon(CupertinoIcons.add),
            ),
          ),
          entriesAsync.when(
            loading: () => const SliverFillRemaining(
              child: Center(child: CupertinoActivityIndicator()),
            ),
            error: (error, _) => SliverFillRemaining(
              child: Center(child: Text('Failed to load: $error')),
            ),
            data: (entries) {
              if (entries.isEmpty) {
                return const SliverFillRemaining(
                  child: Center(child: Text('No integrations configured')),
                );
              }
              return SliverSafeArea(
                top: false,
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    const SizedBox(height: 16),
                    CupertinoListSection.insetGrouped(
                      children: [
                        for (final entry in entries)
                          CupertinoListTile(
                            leading: const IconBadge(
                              icon: CupertinoIcons.cube_box,
                              color: CupertinoColors.systemBlue,
                            ),
                            title: Text(entry.title),
                            subtitle: Text('${entry.domain} · ${entry.state}'),
                            trailing: const CupertinoListTileChevron(),
                            onTap: () => _showActions(context, ref, entry),
                          ),
                      ],
                    ),
                  ]),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showActions(
    BuildContext context,
    WidgetRef ref,
    ConfigEntry entry,
  ) async {
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(entry.title),
        message: Text('${entry.domain} · ${entry.state}'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'reload'),
            child: const Text('Reload'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'delete'),
            isDestructiveAction: true,
            child: const Text('Delete'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );

    final notifier = ref.read(configEntriesProvider.notifier);
    if (action == 'reload') {
      await notifier.reload(entry.entryId);
    } else if (action == 'delete') {
      await notifier.delete(entry.entryId);
    }
  }
}
