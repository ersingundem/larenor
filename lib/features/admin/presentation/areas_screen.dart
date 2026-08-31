import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/admin_providers.dart';

class AreasScreen extends ConsumerWidget {
  const AreasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final areasAsync = ref.watch(areasProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Areas'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => ref.invalidate(areasProvider),
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: areasAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (areas) {
            if (areas.isEmpty) {
              return const Center(child: Text('No areas configured'));
            }
            return ListView(
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  children: [
                    for (final area in areas)
                      CupertinoListTile(
                        leading: const Icon(CupertinoIcons.square_grid_2x2),
                        title: Text(area.name),
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
