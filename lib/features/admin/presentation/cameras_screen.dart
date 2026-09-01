import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/camera_snapshot.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import 'camera_viewer_screen.dart';

class CamerasScreen extends ConsumerWidget {
  const CamerasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final entitiesAsync = ref.watch(entitiesProvider);

    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(largeTitle: Text(l10n.settingsCameras)),
          entitiesAsync.when(
            loading: () => const SliverFillRemaining(
              child: Center(child: CupertinoActivityIndicator()),
            ),
            error: (error, _) => SliverFillRemaining(
              child: Center(child: Text(l10n.adminLoadError(error.toString()))),
            ),
            data: (entities) {
              final cameras =
                  entities.values.where((e) => e.domain == 'camera').toList()
                    ..sort((a, b) => a.friendlyName.compareTo(b.friendlyName));
              if (cameras.isEmpty) {
                return SliverFillRemaining(
                  child: Center(child: Text(l10n.camerasScreenEmpty)),
                );
              }
              return SliverSafeArea(
                top: false,
                sliver: SliverPadding(
                  padding: const EdgeInsets.all(12),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1.3,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final camera = cameras[index];
                      return GestureDetector(
                        onTap: () => Navigator.of(context).push(
                          CupertinoPageRoute(
                            builder: (_) => CameraViewerScreen(
                              entityId: camera.entityId,
                              title: camera.friendlyName,
                            ),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CameraSnapshot(entityId: camera.entityId),
                              Positioned(
                                left: 8,
                                bottom: 8,
                                child: Text(
                                  camera.friendlyName,
                                  style: const TextStyle(
                                    color: CupertinoColors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }, childCount: cameras.length),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
