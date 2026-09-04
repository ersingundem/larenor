import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/app_page_scaffold.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../providers/admin_providers.dart';
import '../data/models/ha_area.dart';
import 'widgets/admin_dialogs.dart';

class AreasScreen extends ConsumerWidget {
  const AreasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final areasAsync = ref.watch(areasProvider);

    return AppPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.settingsAreas),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => _edit(context, ref),
              child: const Icon(CupertinoIcons.add),
            ),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => ref.invalidate(areasProvider),
              child: const Icon(CupertinoIcons.refresh),
            ),
          ),
          areasAsync.when(
            loading: () => const SliverFillRemaining(
              child: Center(child: CupertinoActivityIndicator()),
            ),
            error: (error, _) => SliverFillRemaining(
              child: Center(child: Text(l10n.adminLoadError(error.toString()))),
            ),
            data: (areas) {
              if (areas.isEmpty) {
                return SliverFillRemaining(
                  child: Center(child: Text(l10n.areasScreenEmpty)),
                );
              }
              return SliverSafeArea(
                top: false,
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    const SizedBox(height: 16),
                    SettingsSection(
                      children: [
                        for (final area in areas)
                          CupertinoListTile(
                            leading: IconBadge(
                              icon: CupertinoIcons.square_grid_2x2,
                              color: CupertinoColors.systemGreen.resolveFrom(
                                context,
                              ),
                            ),
                            title: Text(area.name),
                            trailing: const CupertinoListTileChevron(),
                            onTap: () => _actions(context, ref, area),
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

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, [
    HaArea? area,
  ]) async {
    final client = ref.read(haAdminClientProvider);
    if (client == null) return;
    final name = await promptAdminName(
      context,
      title: area == null
          ? AppLocalizations.of(context).adminAddArea
          : AppLocalizations.of(context).adminEditArea,
      initial: area?.name ?? '',
    );
    if (name == null || !context.mounted) return;
    try {
      if (area == null) {
        await client.createArea(name);
      } else {
        await client.updateArea(area.areaId, name);
      }
      if (context.mounted) ref.invalidate(areasProvider);
    } catch (error) {
      if (context.mounted) await showAdminMessage(context, error.toString());
    }
  }

  Future<void> _actions(
    BuildContext context,
    WidgetRef ref,
    HaArea area,
  ) async {
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(area.name),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'edit'),
            child: Text(AppLocalizations.of(context).commonEdit),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, 'delete'),
            child: Text(AppLocalizations.of(context).commonDelete),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'edit') {
      await _edit(context, ref, area);
      return;
    }
    if (action != 'delete') return;
    final confirm = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(AppLocalizations.of(context).commonDelete),
        content: Text(AppLocalizations.of(context).adminDeleteAreaMessage),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context).commonCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context).commonDelete),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;
    try {
      await ref.read(haAdminClientProvider)?.deleteArea(area.areaId);
      if (!context.mounted) return;
      ref.invalidate(areasProvider);
      ref.invalidate(devicesProvider);
      ref.invalidate(entityRegistryProvider);
    } catch (error) {
      if (context.mounted) await showAdminMessage(context, error.toString());
    }
  }
}
