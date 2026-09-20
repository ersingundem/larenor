import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../../../shared/widgets/integration_health_status.dart';
import '../../health/data/integration_health.dart';
import '../../health/providers/health_providers.dart';
import '../data/admin_client.dart';
import '../data/models/config_entry.dart';
import '../providers/admin_providers.dart';
import 'add_integration_screen.dart';
import 'pending_flows_screen.dart';
import 'widgets/admin_dialogs.dart';

class IntegrationsScreen extends ConsumerStatefulWidget {
  const IntegrationsScreen({super.key});

  @override
  ConsumerState<IntegrationsScreen> createState() => _IntegrationsScreenState();
}

class _IntegrationsScreenState extends ConsumerState<IntegrationsScreen> {
  bool _busy = false;

  bool _current(
    HaAdminClient? client,
    AppInteractionController? interaction,
    int? epoch,
  ) =>
      mounted &&
      ModalRoute.of(context)?.isCurrent == true &&
      TickerMode.valuesOf(context).enabled &&
      identical(client, ref.read(haAdminClientProvider)) &&
      identical(interaction, AppInteractionScope.maybeRead(context)) &&
      interaction?.active != false &&
      interaction?.epoch == epoch;

  bool _entryCurrent(ConfigEntry entry) {
    final entries = ref.read(configEntriesProvider);
    return !entries.isLoading &&
        !entries.hasError &&
        entries.value?.contains(entry) == true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final entriesAsync = ref.watch(configEntriesProvider);
    final client = ref.watch(haAdminClientProvider);
    final haHealth =
        ref.watch(integrationHealthProvider(IntegrationId.ha)).value ??
        ref.read(healthMonitorProvider).read(IntegrationId.ha);
    final interaction = AppInteractionScope.maybeOf(context);
    final interactionEpoch = interaction?.epoch;
    bool current() => _current(client, interaction, interactionEpoch);

    return ServiceRootScaffold(
      title: l10n.settingsIntegrations,
      leading: CupertinoButton(
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.zero,
        onPressed: _busy
            ? null
            : () {
                if (current()) ref.invalidate(configEntriesProvider);
              },
        child: const Icon(CupertinoIcons.refresh),
      ),
      trailing: CupertinoButton(
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.zero,
        onPressed: _busy
            ? null
            : () {
                if (current()) {
                  Navigator.of(context).push(
                    CupertinoPageRoute(
                      builder: (_) => const AddIntegrationScreen(),
                    ),
                  );
                }
              },
        child: const Icon(CupertinoIcons.add),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            children: [
              Padding(
                key: const ValueKey('ha-integrations-connection-evidence'),
                padding: const EdgeInsets.all(16),
                child: IntegrationHealthStatus(
                  id: IntegrationId.ha,
                  configured: haHealth.configured,
                ),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(l10n.adminPendingFlows),
            children: [
              SettingsActionTile(
                buttonKey: const ValueKey('ha-integrations-pending-action'),
                leading: const Icon(CupertinoIcons.exclamationmark_bubble),
                title: Text(l10n.adminPendingFlows),
                onTap: _busy
                    ? null
                    : () {
                        if (current()) {
                          Navigator.of(context).push(
                            CupertinoPageRoute<void>(
                              builder: (_) => const PendingFlowsScreen(),
                            ),
                          );
                        }
                      },
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
                    header: Semantics(
                      key: const ValueKey('ha-integrations-list-header'),
                      header: true,
                      child: Text(l10n.settingsIntegrations),
                    ),
                    children: [
                      for (final entry in entries)
                        SettingsActionTile(
                          buttonKey: ValueKey(
                            'ha-integration-${entry.entryId}',
                          ),
                          leading: IconBadge(
                            icon: CupertinoIcons.cube_box,
                            color: CupertinoColors.systemBlue.resolveFrom(
                              context,
                            ),
                          ),
                          title: Text(entry.title),
                          additionalInfo: Text(
                            '${entry.domain} · ${entry.state}',
                          ),
                          onTap: _busy
                              ? null
                              : () => _showActions(
                                  entry,
                                  client,
                                  interaction,
                                  interactionEpoch,
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
    );
  }

  Future<void> _showActions(
    ConfigEntry entry,
    HaAdminClient? client,
    AppInteractionController? interaction,
    int? interactionEpoch,
  ) async {
    if (_busy ||
        !_current(client, interaction, interactionEpoch) ||
        !_entryCurrent(entry)) {
      return;
    }
    setState(() => _busy = true);
    final l10n = AppLocalizations.of(context);
    try {
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
                entry.disabledBy == null
                    ? l10n.commonDisable
                    : l10n.commonEnable,
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

      if (!mounted) return;
      if (action == null ||
          client == null ||
          !_current(client, interaction, interactionEpoch) ||
          !_entryCurrent(entry)) {
        return;
      }
      var restart = false;
      if (action == 'options' || action == 'reconfigure') {
        if (!mounted) return;
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
        if (!mounted) return;
        final title = await promptAdminName(
          context,
          title: l10n.commonEdit,
          initial: entry.title,
        );
        if (title == null ||
            !_current(client, interaction, interactionEpoch) ||
            !_entryCurrent(entry)) {
          return;
        }
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
        if (!mounted) return;
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
        if (confirmed != true ||
            !_current(client, interaction, interactionEpoch) ||
            !_entryCurrent(entry)) {
          return;
        }
        restart = await client.deleteConfigEntry(entry.entryId);
      }
      if (!_current(client, interaction, interactionEpoch)) return;
      ref.invalidate(configEntriesProvider);
      if (restart) {
        if (!mounted) return;
        await showAdminMessage(
          context,
          l10n.adminRestartRequired,
          error: false,
        );
      }
    } catch (error) {
      if (mounted && _current(client, interaction, interactionEpoch)) {
        await showAdminMessage(context, error.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
