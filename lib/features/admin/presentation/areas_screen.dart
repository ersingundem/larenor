import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../media/hub/presentation/media_session_state.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../data/admin_client.dart';
import '../providers/admin_providers.dart';
import '../data/models/ha_area.dart';
import 'widgets/admin_dialogs.dart';

class AreasScreen extends ConsumerStatefulWidget {
  const AreasScreen({super.key});

  @override
  ConsumerState<AreasScreen> createState() => _AreasScreenState();
}

class _AreasScreenState extends MediaSessionState<AreasScreen> {
  bool _current(int generation, HaAdminClient client) =>
      sessionCurrent(generation) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true &&
      identical(ref.read(haAdminClientProvider), client);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final areasAsync = ref.watch(areasProvider);
    final client = ref.watch(haAdminClientProvider);
    final generation = sessionGeneration;
    final active = client != null && _current(generation, client);

    return ServiceRootScaffold(
      title: l10n.settingsAreas,
      trailing: CupertinoButton(
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.zero,
        onPressed: active ? () => _edit(generation, client) : null,
        child: const Icon(CupertinoIcons.add),
      ),
      leading: CupertinoButton(
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.zero,
        onPressed: active
            ? () {
                if (_current(generation, client)) {
                  ref.invalidate(areasProvider);
                }
              }
            : null,
        child: const Icon(CupertinoIcons.refresh),
      ),
      slivers: [
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
                    header: Semantics(
                      key: const ValueKey('areas-list-header'),
                      header: true,
                      child: Text(l10n.settingsAreas),
                    ),
                    children: [
                      for (final area in areas)
                        SettingsActionTile(
                          buttonKey: ValueKey('admin-area-${area.areaId}'),
                          leading: IconBadge(
                            icon: CupertinoIcons.square_grid_2x2,
                            color: CupertinoColors.systemGreen.resolveFrom(
                              context,
                            ),
                          ),
                          title: Text(area.name),
                          onTap: active
                              ? () => _actions(generation, client, area)
                              : null,
                        ),
                    ],
                  ),
                ]),
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _edit(
    int generation,
    HaAdminClient client, [
    HaArea? area,
  ]) async {
    if (!_current(generation, client)) return;
    final name = await promptAdminName(
      context,
      title: area == null
          ? AppLocalizations.of(context).adminAddArea
          : AppLocalizations.of(context).adminEditArea,
      initial: area?.name ?? '',
    );
    if (name == null || !mounted || !_current(generation, client)) return;
    try {
      if (area == null) {
        await client.createArea(name);
      } else {
        await client.updateArea(area.areaId, name);
      }
      if (mounted && _current(generation, client)) {
        ref.invalidate(areasProvider);
      }
    } catch (error) {
      if (mounted && _current(generation, client)) {
        await showAdminMessage(context, error.toString());
      }
    }
  }

  Future<void> _actions(
    int generation,
    HaAdminClient client,
    HaArea area,
  ) async {
    if (!_current(generation, client)) return;
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
    if (!mounted || !_current(generation, client)) return;
    if (action == 'edit') {
      await _edit(generation, client, area);
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
    if (confirm != true || !mounted || !_current(generation, client)) return;
    try {
      await client.deleteArea(area.areaId);
      if (!mounted || !_current(generation, client)) return;
      ref.invalidate(areasProvider);
      ref.invalidate(devicesProvider);
      ref.invalidate(entityRegistryProvider);
    } catch (error) {
      if (mounted && _current(generation, client)) {
        await showAdminMessage(context, error.toString());
      }
    }
  }
}
