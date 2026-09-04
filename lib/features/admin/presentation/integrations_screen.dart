import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/app_page_scaffold.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../data/models/config_entry.dart';
import '../providers/admin_providers.dart';
import 'add_integration_screen.dart';
import 'pending_flows_screen.dart';
import 'widgets/admin_dialogs.dart';

class IntegrationsScreen extends ConsumerWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final entriesAsync = ref.watch(configEntriesProvider);

    return AppPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.settingsIntegrations),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => ref.invalidate(configEntriesProvider),
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
          SliverToBoxAdapter(
            child: SettingsSection(
              children: [
                CupertinoListTile(
                  leading: const Icon(CupertinoIcons.exclamationmark_bubble),
                  title: Text(l10n.adminPendingFlows),
                  trailing: const CupertinoListTileChevron(),
                  onTap: () => Navigator.of(context).push(
                    CupertinoPageRoute<void>(
                      builder: (_) => const PendingFlowsScreen(),
                    ),
                  ),
                ),
              ],
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
                    SettingsSection(
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
          if (entry.supportsOptions && entry.disabledBy == null)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, 'options'),
              child: Text(l10n.adminOptions),
            ),
          if (entry.supportsReconfigure && entry.disabledBy == null)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, 'reconfigure'),
              child: Text(l10n.adminReconfigure),
            ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'rename'),
            child: Text(l10n.commonEdit),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'disable'),
            child: Text(
              entry.disabledBy == null ? l10n.commonDisable : l10n.commonEnable,
            ),
          ),
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

    if (action == null || !context.mounted) return;
    final client = ref.read(haAdminClientProvider);
    if (client == null) return;
    try {
      var restart = false;
      if (action == 'options' || action == 'reconfigure') {
        await Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => AddIntegrationScreen(
              handler: action == 'options' ? entry.entryId : entry.domain,
              entryId: action == 'reconfigure' ? entry.entryId : null,
              options: action == 'options',
            ),
          ),
        );
      } else if (action == 'rename') {
        final title = await promptAdminName(
          context,
          title: l10n.commonEdit,
          initial: entry.title,
        );
        if (title == null || !context.mounted) return;
        restart =
            (await client.updateConfigEntry(entry.entryId, {
              'title': title,
            }))['require_restart'] ==
            true;
      } else if (action == 'disable') {
        restart =
            (await client.setConfigEntryDisabled(
              entry.entryId,
              entry.disabledBy == null,
            ))['require_restart'] ==
            true;
      } else if (action == 'reload') {
        restart = await client.reloadConfigEntry(entry.entryId);
      } else if (action == 'delete') {
        final confirmed = await showCupertinoDialog<bool>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: Text(l10n.commonDelete),
            content: Text(l10n.adminConfirmDelete),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.commonCancel),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.commonDelete),
              ),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) return;
        restart = await client.deleteConfigEntry(entry.entryId);
      }
      if (!context.mounted) return;
      ref.invalidate(configEntriesProvider);
      if (restart) {
        await showAdminMessage(
          context,
          l10n.adminRestartRequired,
          error: false,
        );
      }
    } catch (error) {
      if (context.mounted) await showAdminMessage(context, error.toString());
    }
  }
}
