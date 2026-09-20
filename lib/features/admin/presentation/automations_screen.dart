import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/integration_health_status.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/service_route_status_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/data/rest_client.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../health/data/integration_health.dart';
import '../data/models/automation_summary.dart';
import '../providers/admin_providers.dart';
import 'admin_session_state.dart';
import 'automation_editor_screen.dart';

class AutomationsScreen extends ConsumerStatefulWidget {
  const AutomationsScreen({super.key});

  @override
  ConsumerState<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends AdminSessionState<AutomationsScreen> {
  final _pending = <String>{};
  late final HaRestClient? _restClient;
  bool _actionFailed = false;

  @override
  void initState() {
    super.initState();
    _restClient = ref.read(haRestClientProvider);
  }

  @override
  void adminSessionExpired() {
    _pending.clear();
    _actionFailed = false;
  }

  bool _current(int generation) =>
      adminActionCurrent(generation) &&
      _restClient != null &&
      identical(_restClient, ref.read(haRestClientProvider));

  bool _modalResultCurrent(int session) =>
      adminAuthorityCurrent &&
      sessionCurrent(session) &&
      _restClient != null &&
      identical(_restClient, ref.read(haRestClientProvider)) &&
      ModalRoute.of(context)?.isCurrent == true;

  void _refresh(int generation) {
    if (!_current(generation)) return;
    setState(() => _actionFailed = false);
    ref.invalidate(automationsProvider);
  }

  void _openEditor(int generation) {
    if (!_current(generation)) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(builder: (_) => const AutomationEditorScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    watchAdminSession();
    ref.watch(haRestClientProvider);
    final l10n = AppLocalizations.of(context);
    final automationsAsync = ref.watch(automationsProvider);
    final liveEntities = ref.watch(entitiesProvider).value;
    final generation = adminActionGeneration;
    final active = _current(generation);

    if (!adminAuthorityCurrent || _restClient == null) {
      return ServiceRouteStatusScaffold(
        title: l10n.settingsAutomations,
        label: l10n.adminEditorSessionChanged,
        statusKey: const ValueKey('automations-expired'),
      );
    }

    return automationsAsync.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      skipError: false,
      loading: () => ServiceRouteStatusScaffold(
        title: l10n.settingsAutomations,
        label: l10n.commonLoading,
        statusKey: const ValueKey('automations-loading'),
        loading: true,
      ),
      error: (_, _) => ServiceRouteStatusScaffold(
        title: l10n.settingsAutomations,
        label: l10n.commonError,
        statusKey: const ValueKey('automations-error'),
        actionLabel: l10n.commonRetry,
        actionKey: const ValueKey('automations-retry'),
        onAction: active ? () => _refresh(generation) : null,
      ),
      data: (automations) {
        if (automations.isEmpty) {
          return ServiceRouteStatusScaffold(
            title: l10n.settingsAutomations,
            label: l10n.automationsScreenEmpty,
            statusKey: const ValueKey('automations-empty'),
            actionLabel: l10n.commonRefresh,
            actionKey: const ValueKey('automations-retry'),
            onAction: active ? () => _refresh(generation) : null,
          );
        }
        return ServiceRootScaffold(
          title: l10n.settingsAutomations,
          leading: _NavigationAction(
            key: const ValueKey('automations-refresh'),
            label: l10n.commonRefresh,
            icon: CupertinoIcons.refresh,
            onPressed: active ? () => _refresh(generation) : null,
          ),
          trailing: _NavigationAction(
            key: const ValueKey('automations-add'),
            label: l10n.automationEditorNewTitle,
            icon: CupertinoIcons.add,
            onPressed: active ? () => _openEditor(generation) : null,
          ),
          slivers: [
            SliverToBoxAdapter(
              child: SettingsSection(
                header: Semantics(
                  key: const ValueKey('automations-heading'),
                  header: true,
                  child: Text(l10n.settingsAutomations),
                ),
                children: [
                  const CupertinoListTile(
                    title: IntegrationHealthStatus(
                      id: IntegrationId.ha,
                      configured: true,
                    ),
                  ),
                  if (_actionFailed)
                    Semantics(
                      key: const ValueKey('automations-action-error'),
                      liveRegion: true,
                      label: l10n.actionFailed,
                      excludeSemantics: true,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(l10n.actionFailed),
                      ),
                    ),
                  for (final automation in automations)
                    _AutomationRow(
                      automation: automation,
                      liveEntity: liveEntities?[automation.entityId],
                      pending: _pending.contains(automation.entityId),
                      enabled: active,
                      onOpen: () => _actions(automation, generation),
                      onToggle: () => _run(
                        automation.entityId,
                        (liveEntities?[automation.entityId]?.isOn ??
                                automation.isOn)
                            ? 'turn_off'
                            : 'turn_on',
                        generation,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _run(String entityId, String service, int generation) async {
    final rest = _restClient;
    if (rest == null || !_current(generation) || _pending.contains(entityId)) {
      return;
    }
    setState(() {
      _pending.add(entityId);
      _actionFailed = false;
    });
    try {
      await rest.callService(
        'automation',
        service,
        entityId: entityId,
        serviceData: service == 'trigger' ? {'skip_condition': false} : null,
      );
      if (_current(generation)) ref.invalidate(entitiesProvider);
    } catch (_) {
      if (_current(generation)) setState(() => _actionFailed = true);
    } finally {
      if (_current(generation)) {
        setState(() => _pending.remove(entityId));
      }
    }
  }

  Future<void> _actions(AutomationSummary automation, int generation) async {
    if (!_current(generation)) return;
    final session = sessionGeneration;
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
    if (!mounted || action == null || !_modalResultCurrent(session)) return;
    final nextGeneration = adminActionGeneration;
    if (action == 'run') {
      await _run(automation.entityId, 'trigger', nextGeneration);
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
    final client = adminClient;
    if (client == null || !_current(nextGeneration)) return;
    try {
      final config = await client.getAutomationConfig(automation.automationId!);
      if (!mounted || !_current(nextGeneration)) return;
      final copy = Map<String, dynamic>.from(config)..remove('id');
      copy['alias'] = '${automation.friendlyName} (${l10n.adminDuplicate})';
      await Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => AutomationEditorScreen(initialConfig: copy),
        ),
      );
    } catch (_) {
      if (_current(nextGeneration)) setState(() => _actionFailed = true);
    }
  }
}

class _NavigationAction extends StatelessWidget {
  const _NavigationAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: label,
    child: ExcludeSemantics(
      child: CupertinoButton(
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        child: Icon(icon),
      ),
    ),
  );
}

class _AutomationRow extends StatelessWidget {
  const _AutomationRow({
    required this.automation,
    required this.liveEntity,
    required this.pending,
    required this.enabled,
    required this.onOpen,
    required this.onToggle,
  });

  final AutomationSummary automation;
  final HaEntity? liveEntity;
  final bool pending;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final value = liveEntity?.isOn ?? automation.isOn;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              key: ValueKey('automation-action-${automation.entityId}'),
              button: true,
              enabled: enabled,
              label: [
                automation.friendlyName,
                automationSubtitle(l10n, automation, liveEntity),
              ].join('. '),
              child: ExcludeSemantics(
                child: CupertinoButton(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 10, 6),
                  alignment: AlignmentDirectional.centerStart,
                  onPressed: enabled ? onOpen : null,
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.bolt, size: 28),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(automation.friendlyName, maxLines: 2),
                            Text(
                              automationSubtitle(l10n, automation, liveEntity),
                              maxLines: 2,
                              style: TextStyle(
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const CupertinoListTileChevron(),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Semantics(
            key: ValueKey('automation-toggle-${automation.entityId}'),
            button: true,
            enabled: enabled && !pending,
            toggled: value,
            label: '${automation.friendlyName}, ${l10n.adminEnabled}',
            child: ExcludeSemantics(
              child: CupertinoButton(
                key: ValueKey(
                  'automation-toggle-control-${automation.entityId}',
                ),
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                onPressed: enabled && !pending ? onToggle : null,
                child: pending
                    ? const CupertinoActivityIndicator()
                    : IgnorePointer(
                        child: CupertinoSwitch(
                          value: value,
                          onChanged: enabled ? (_) {} : null,
                        ),
                      ),
              ),
            ),
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
