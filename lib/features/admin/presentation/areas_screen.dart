import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/icon_badge.dart';
import '../providers/admin_providers.dart';

class AreasScreen extends ConsumerWidget {
  const AreasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final areasAsync = ref.watch(areasProvider);

    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: const Text('Areas'),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => ref.invalidate(areasProvider),
              child: const Icon(CupertinoIcons.refresh),
            ),
          ),
          areasAsync.when(
            loading: () => const SliverFillRemaining(
              child: Center(child: CupertinoActivityIndicator()),
            ),
            error: (error, _) => SliverFillRemaining(
              child: Center(child: Text('Failed to load: $error')),
            ),
            data: (areas) {
              if (areas.isEmpty) {
                return const SliverFillRemaining(
                  child: Center(child: Text('No areas configured')),
                );
              }
              return SliverSafeArea(
                top: false,
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    const SizedBox(height: 16),
                    CupertinoListSection.insetGrouped(
                      children: [
                        for (final area in areas)
                          CupertinoListTile(
                            leading: const IconBadge(
                              icon: CupertinoIcons.square_grid_2x2,
                              color: CupertinoColors.systemGreen,
                            ),
                            title: Text(area.name),
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
}
