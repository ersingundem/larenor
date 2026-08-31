import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    final entitiesAsync = ref.watch(entityRegistryProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Entities'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => ref.invalidate(entityRegistryProvider),
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: entitiesAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
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

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: CupertinoSearchTextField(
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final entity = filtered[index];
                      final disabled = entity.disabledBy != null;
                      return CupertinoListTile(
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
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
