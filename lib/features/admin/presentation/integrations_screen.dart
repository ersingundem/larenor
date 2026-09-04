import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../data/models/config_entry.dart';
import '../providers/admin_providers.dart';
import 'add_integration_screen.dart';

class IntegrationsScreen extends ConsumerWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final entriesAsync = ref.watch(configEntriesProvider);

    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.settingsIntegrations),
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
              child: Center(child: Text(l10n.adminLoadError(error.toString()))),
            ),
            data: (entries) {
              if (entries.isEmpty) {
                return SliverFillRemaining(
                  child: Center(child: Text(l10n.integrationsScreenEmpty)),
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
                            leading: IconBadge(
                              icon: CupertinoIcons.cube_box,
                              color: CupertinoColors.systemBlue.resolveFrom(
                                context,
                              ),
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
    final l10n = AppLocalizations.of(context);
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(entry.title),
        message: Text('${entry.domain} · ${entry.state}'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'reload'),
            child: Text(l10n.integrationsReloadAction),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'delete'),
            isDestructiveAction: true,
            child: Text(l10n.commonDelete),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
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
