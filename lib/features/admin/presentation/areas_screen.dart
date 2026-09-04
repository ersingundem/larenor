import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../providers/admin_providers.dart';

class AreasScreen extends ConsumerWidget {
  const AreasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final areasAsync = ref.watch(areasProvider);

    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.settingsAreas),
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
              child: Center(child: Text(l10n.adminLoadError(error.toString()))),
            ),
            data: (areas) {
              if (areas.isEmpty) {
                return SliverFillRemaining(
                  child: Center(child: Text(l10n.areasScreenEmpty)),
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
                            leading: IconBadge(
                              icon: CupertinoIcons.square_grid_2x2,
                              color: CupertinoColors.systemGreen.resolveFrom(
                                context,
                              ),
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
