import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    final automationsAsync = ref.watch(automationsProvider);
    final liveEntities = ref.watch(entitiesProvider).value;

    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: const Text('Automations'),
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
              child: Center(child: Text('Failed to load: $error')),
            ),
            data: (automations) {
              if (automations.isEmpty) {
                return const SliverFillRemaining(
                  child: Center(child: Text('No automations found')),
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
String automationSubtitle(AutomationSummary automation, HaEntity? liveEntity) {
  if (automation.automationId == null) return 'Config not editable from here';
  final lastTriggered = liveEntity?.attributes['last_triggered'] as String?;
  if (lastTriggered == null) return 'Never triggered';
  final parsed = DateTime.tryParse(lastTriggered);
  if (parsed == null) return 'Last triggered: $lastTriggered';
  return 'Last triggered: ${parsed.toLocal().toString().split('.')[0]}';
}
