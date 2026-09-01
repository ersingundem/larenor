import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/category_colors.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../providers/admin_providers.dart';

class EntitiesScreen extends ConsumerStatefulWidget {
  const EntitiesScreen({super.key});

  @override
  ConsumerState<EntitiesScreen> createState() => _EntitiesScreenState();
}

class _EntitiesScreenState extends ConsumerState<EntitiesScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final entitiesAsync = ref.watch(entityRegistryProvider);

    return CupertinoPageScaffold(
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
                            color: categoryColorForDomain(domain),
                          ),
                          title: Text(entity.displayName),
                          subtitle: Text(entity.entityId),
                          trailing: CupertinoSwitch(
                            value: !disabled,
                            onChanged: (enabled) => ref
                                .read(entityRegistryProvider.notifier)
                                .setDisabled(entity.entityId, !enabled),
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
