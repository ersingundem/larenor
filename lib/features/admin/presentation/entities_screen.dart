import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/app_page_scaffold.dart';

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

    return AppPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.settingsEntities),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => ref.invalidate(entityRegistryProvider),
              child: const Icon(CupertinoIcons.refresh),
            ),
          ),
          entitiesAsync.when(
            loading: () => const SliverFillRemaining(
              child: Center(child: CupertinoActivityIndicator()),
            ),
            error: (error, _) => SliverFillRemaining(
              child: Center(child: Text(l10n.adminLoadError(error.toString()))),
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
                sliver: SliverMainAxisGroup(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: CupertinoSearchTextField(
                          onChanged: (value) => setState(() => _query = value),
                        ),
                      ),
                    ),
                    SliverList.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final entity = filtered[index];
                        final disabled = entity.disabledBy != null;
                        final domain = entity.entityId.split('.').first;
                        return CupertinoListTile(
                          leading: IconBadge(
                            icon: CupertinoIcons.list_bullet,
                            color: categoryColorForDomain(context, domain),
                          ),
                          title: Text(entity.displayName),
                          subtitle: Text(entity.entityId),
                          onTap: () => Navigator.of(context).push(
                            CupertinoPageRoute<String>(
                              builder: (_) =>
                                  RegistryEditorScreen.entity(entity),
                            ),
                          ),
                          trailing: CupertinoSwitch(
                            value: !disabled,
                            onChanged: _pending.contains(entity.entityId)
                                ? null
                                : (enabled) =>
                                      _setEnabled(entity.entityId, enabled),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
