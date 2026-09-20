import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/settings_service_tile.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/category_colors.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../providers/admin_providers.dart';
import 'registry_editor_screen.dart';
import 'widgets/admin_dialogs.dart';

class EntitiesScreen extends ConsumerStatefulWidget {
  const EntitiesScreen({super.key});

  @override
  ConsumerState<EntitiesScreen> createState() => _EntitiesScreenState();
}

class _EntitiesScreenState extends ConsumerState<EntitiesScreen> {
  String _query = '';
  final _pending = <String>{};

  Future<void> _setEnabled(String entityId, bool enabled) async {
    setState(() => _pending.add(entityId));
    try {
      final response = await ref.read(haAdminClientProvider)?.updateEntity(
        entityId,
        {'disabled_by': enabled ? null : 'user'},
      );
      if (!mounted) return;
      ref.invalidate(entityRegistryProvider);
      if (response?['require_restart'] == true) {
        await showAdminMessage(
          context,
          AppLocalizations.of(context).adminRestartRequired,
          error: false,
        );
      }
    } catch (error) {
      if (mounted) await showAdminMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _pending.remove(entityId));
    }
  }

  @override
  Widget build(BuildContext context) {
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
                onTap: () => ref.invalidate(entityRegistryProvider),
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
                        busy: _pending.contains(entity.entityId),
                        openKey: ValueKey('entity-${entity.entityId}'),
                        toggleKey: ValueKey('entity-toggle-${entity.entityId}'),
                        onOpen: () => Navigator.of(context).push(
                          CupertinoPageRoute<String>(
                            builder: (_) => RegistryEditorScreen.entity(entity),
                          ),
                        ),
                        onToggle: _pending.contains(entity.entityId)
                            ? null
                            : (enabled) =>
                                  _setEnabled(entity.entityId, enabled),
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
