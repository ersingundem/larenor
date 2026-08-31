import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ha_client/providers/ha_client_providers.dart';
import '../providers/admin_providers.dart';
import 'automation_editor_screen.dart';

class AutomationsScreen extends ConsumerWidget {
  const AutomationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final automationsAsync = ref.watch(automationsProvider);
    final liveEntities = ref.watch(entitiesProvider).value;

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Automations'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => ref.invalidate(automationsProvider),
          child: const Icon(CupertinoIcons.refresh),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).push(
            CupertinoPageRoute(builder: (_) => const AutomationEditorScreen()),
          ),
          child: const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: automationsAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (automations) {
            if (automations.isEmpty) {
              return const Center(child: Text('No automations found'));
            }
            return ListView(
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  children: [
                    for (final automation in automations)
                      CupertinoListTile(
                        title: Text(automation.friendlyName),
                        subtitle: automation.automationId == null
                            ? const Text('Config not editable from here')
                            : null,
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
              ],
            );
          },
        ),
      ),
    );
  }
}
