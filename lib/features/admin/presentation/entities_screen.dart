import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/settings_service_tile.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/category_colors.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../../dashboard/presentation/dashboard_edit_guard.dart';
import '../data/admin_client.dart';
import '../data/models/ha_registry_entry.dart';
import '../providers/admin_providers.dart';
import 'registry_editor_screen.dart';
import 'widgets/admin_dialogs.dart';

class EntitiesScreen extends ConsumerStatefulWidget {
  const EntitiesScreen({super.key});

  @override
  ConsumerState<EntitiesScreen> createState() => _EntitiesScreenState();
}

class _EntitiesScreenState extends DashboardEditState<EntitiesScreen> {
  String _query = '';
  final _pending = <String, Object>{};

  @override
  void invalidateDashboardInteraction() {
    _pending.clear();
  }

  bool _authorityCurrent(int generation, HaAdminClient? client) =>
      interactionCurrent(generation) &&
      identical(client, ref.read(haAdminClientProvider));

  HaRegistryEntry? _currentEntity(HaRegistryEntry captured) {
    final registry = ref.read(entityRegistryProvider);
    if (registry.isLoading || registry.hasError) return null;
    for (final entity in registry.value ?? const <HaRegistryEntry>[]) {
      if (identical(entity, captured)) return entity;
    }
    return null;
  }

  Future<void> _setEnabled(
    HaRegistryEntry captured,
    bool enabled,
    int generation,
    HaAdminClient? client,
  ) async {
    final entityId = captured.entityId;
    if (_pending.containsKey(entityId) ||
        !_authorityCurrent(generation, client) ||
        client == null ||
        _currentEntity(captured) == null) {
      return;
    }
    final operation = Object();
    setState(() => _pending[entityId] = operation);
    try {
      final response = await client.updateEntity(entityId, {
        'disabled_by': enabled ? null : 'user',
      });
      if (!mounted ||
          !_authorityCurrent(generation, client) ||
          !identical(_pending[entityId], operation)) {
        return;
      }
      ref.invalidate(entityRegistryProvider);
      if (response['require_restart'] == true) {
        await showAdminMessage(
          context,
          AppLocalizations.of(context).adminRestartRequired,
          error: false,
        );
      }
    } catch (error) {
      if (mounted &&
          _authorityCurrent(generation, client) &&
          identical(_pending[entityId], operation)) {
        await showAdminMessage(context, error.toString());
      }
    } finally {
      if (mounted && identical(_pending[entityId], operation)) {
        setState(() => _pending.remove(entityId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    watchDashboardAccount();
    final client = ref.watch(haAdminClientProvider);
    final generation = interactionGeneration;
    final l10n = AppLocalizations.of(context);
    final entitiesAsync = ref.watch(entityRegistryProvider);

    return ServiceRootScaffold(
      title: l10n.settingsEntities,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              key: const ValueKey('entities-controls-header'),
              header: true,
              child: Text(l10n.settingsEntities),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: CupertinoSearchTextField(
                    key: const ValueKey('entities-search'),
                    placeholder: l10n.commonSearch,
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
              ),
              SettingsActionTile(
                buttonKey: const ValueKey('entities-refresh-action'),
                title: Text(l10n.commonRefresh),
                onTap: () {
                  if (_authorityCurrent(generation, client)) {
                    ref.invalidate(entityRegistryProvider);
                  }
                },
              ),
            ],
          ),
        ),
        entitiesAsync.when(
          loading: () =>
              const SliverFilledMessage(child: CupertinoActivityIndicator()),
          error: (error, _) => SliverFilledMessage(
            child: Text(l10n.adminLoadError(error.toString())),
          ),
          data: (entities) {
            final filtered = _query.isEmpty
                ? entities
                : entities
                      .where(
                        (e) =>
                            e.displayName.toLowerCase().contains(
                              _query.toLowerCase(),
                            ) ||
                            e.entityId.toLowerCase().contains(
                              _query.toLowerCase(),
                            ),
                      )
                      .toList();

            return SliverSafeArea(
              top: false,
              sliver: SliverToBoxAdapter(
                child: SettingsSection(
                  header: Text('${filtered.length}'),
                  children: [
                    for (final entity in filtered)
                      SettingsServiceTile(
                        title: entity.displayName,
                        leading: IconBadge(
                          icon: CupertinoIcons.list_bullet,
                          color: categoryColorForDomain(
                            context,
                            entity.entityId.split('.').first,
                          ),
                        ),
                        additionalInfo: Text(entity.entityId),
                        enabled: entity.disabledBy == null,
                        busy: _pending.containsKey(entity.entityId),
                        openKey: ValueKey('entity-${entity.entityId}'),
                        toggleKey: ValueKey('entity-toggle-${entity.entityId}'),
                        onOpen: () {
                          final current = _currentEntity(entity);
                          if (!_authorityCurrent(generation, client) ||
                              current == null) {
                            return;
                          }
                          Navigator.of(context).push(
                            CupertinoPageRoute<String>(
                              builder: (_) =>
                                  RegistryEditorScreen.entity(current),
                            ),
                          );
                        },
                        onToggle: _pending.containsKey(entity.entityId)
                            ? null
                            : (enabled) => _setEnabled(
                                entity,
                                enabled,
                                generation,
                                client,
                              ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
