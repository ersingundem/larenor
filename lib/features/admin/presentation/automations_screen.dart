import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/app_page_scaffold.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../data/models/automation_summary.dart';
import '../providers/admin_providers.dart';
import 'automation_editor_screen.dart';
import 'widgets/admin_dialogs.dart';

class AutomationsScreen extends ConsumerStatefulWidget {
  const AutomationsScreen({super.key});

  @override
  ConsumerState<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends ConsumerState<AutomationsScreen> {
  final _pending = <String>{};
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final automationsAsync = ref.watch(automationsProvider);
    final liveEntities = ref.watch(entitiesProvider).value;

    return AppPageScaffold(
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
                    SettingsSection(
                      children: [
                        for (final automation in automations)
                          CupertinoListTile(
                            leading: IconBadge(
                              icon: CupertinoIcons.bolt,
                              color: CupertinoColors.systemOrange.resolveFrom(
                                context,
                              ),
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
                              onChanged: _pending.contains(automation.entityId)
                                  ? null
                                  : (enabled) => _run(
                                      automation.entityId,
                                      enabled ? 'turn_on' : 'turn_off',
                                    ),
                            ),
                            onTap: () => _actions(automation),
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

  Future<void> _run(String entityId, String service) async {
    if (_pending.contains(entityId)) return;
    setState(() => _pending.add(entityId));
    try {
      await ref
          .read(haRestClientProvider)
          ?.callService(
            'automation',
            service,
            entityId: entityId,
            serviceData: service == 'trigger'
                ? {'skip_condition': false}
                : null,
          );
      if (mounted) ref.invalidate(entitiesProvider);
    } catch (error) {
      if (mounted) await showAdminMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _pending.remove(entityId));
    }
  }

  Future<void> _actions(AutomationSummary automation) async {
    final l10n = AppLocalizations.of(context);
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(automation.friendlyName),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'run'),
            child: Text(l10n.adminRunNow),
          ),
          if (automation.automationId != null) ...[
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, 'edit'),
              child: Text(l10n.commonEdit),
            ),
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, 'duplicate'),
              child: Text(l10n.adminDuplicate),
            ),
          ],
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'run') {
      await _run(automation.entityId, 'trigger');
      return;
    }
    if (action == 'edit') {
      await Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) =>
              AutomationEditorScreen(automationId: automation.automationId),
        ),
      );
      return;
    }
    try {
      final config = await ref
          .read(haAdminClientProvider)
          ?.getAutomationConfig(automation.automationId!);
      if (!mounted || config == null) return;
      final copy = Map<String, dynamic>.from(config)..remove('id');
      copy['alias'] = '${automation.friendlyName} (${l10n.adminDuplicate})';
      await Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => AutomationEditorScreen(initialConfig: copy),
        ),
      );
    } catch (error) {
      if (mounted) await showAdminMessage(context, error.toString());
    }
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
