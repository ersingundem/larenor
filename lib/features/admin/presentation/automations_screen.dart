import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../data/models/automation_summary.dart';
import '../providers/admin_providers.dart';
import 'automation_editor_screen.dart';

class AutomationsScreen extends ConsumerWidget {
  const AutomationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final automationsAsync = ref.watch(automationsProvider);
    final liveEntities = ref.watch(entitiesProvider).value;

    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.settingsAutomations),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => ref.invalidate(automationsProvider),
              child: const Icon(CupertinoIcons.refresh),
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.of(context).push(
                CupertinoPageRoute(
                  builder: (_) => const AutomationEditorScreen(),
                ),
              ),
              child: const Icon(CupertinoIcons.add),
            ),
          ),
          automationsAsync.when(
            loading: () => const SliverFillRemaining(
              child: Center(child: CupertinoActivityIndicator()),
            ),
            error: (error, _) => SliverFillRemaining(
              child: Center(child: Text(l10n.adminLoadError(error.toString()))),
            ),
            data: (automations) {
              if (automations.isEmpty) {
                return SliverFillRemaining(
                  child: Center(child: Text(l10n.automationsScreenEmpty)),
                );
              }
              return SliverSafeArea(
                top: false,
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    const SizedBox(height: 16),
                    CupertinoListSection.insetGrouped(
                      children: [
                        for (final automation in automations)
                          CupertinoListTile(
                            leading: const IconBadge(
                              icon: CupertinoIcons.bolt,
                              color: CupertinoColors.systemOrange,
                            ),
                            title: Text(automation.friendlyName),
                            subtitle: Text(
                              automationSubtitle(
                                l10n,
                                automation,
                                liveEntities?[automation.entityId],
                              ),
                            ),
                            trailing: CupertinoSwitch(
                              value:
                                  liveEntities?[automation.entityId]?.isOn ??
                                  automation.isOn,
                              onChanged: (enabled) => ref
                                  .read(haRestClientProvider)
                                  ?.callService(
                                    'automation',
                                    enabled ? 'turn_on' : 'turn_off',
                                    entityId: automation.entityId,
                                  ),
                            ),
                            onTap: automation.automationId == null
                                ? null
                                : () => Navigator.of(context).push(
                                    CupertinoPageRoute(
                                      builder: (_) => AutomationEditorScreen(
                                        automationId: automation.automationId,
                                      ),
                                    ),
                                  ),
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
}

/// Pulled out of [AutomationsScreen] so the subtitle logic is unit
/// testable without standing up the widget tree.
String automationSubtitle(
  AppLocalizations l10n,
  AutomationSummary automation,
  HaEntity? liveEntity,
) {
  if (automation.automationId == null) return l10n.automationsNotEditable;
  final lastTriggered = liveEntity?.attributes['last_triggered'] as String?;
  if (lastTriggered == null) return l10n.automationsNeverTriggered;
  final parsed = DateTime.tryParse(lastTriggered);
  final formatted = parsed == null
      ? lastTriggered
      : parsed.toLocal().toString().split('.')[0];
  return l10n.automationsLastTriggered(formatted);
}
