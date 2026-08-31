import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/camera_snapshot.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import 'camera_viewer_screen.dart';

class CamerasScreen extends ConsumerWidget {
  const CamerasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entitiesAsync = ref.watch(entitiesProvider);

    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Cameras')),
      child: SafeArea(
        child: entitiesAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (entities) {
            final cameras =
                entities.values.where((e) => e.domain == 'camera').toList()
                  ..sort((a, b) => a.friendlyName.compareTo(b.friendlyName));
            if (cameras.isEmpty) {
              return const Center(child: Text('No cameras found'));
            }
            return GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.3,
              ),
              itemCount: cameras.length,
              itemBuilder: (context, index) {
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
              },
            );
          },
        ),
      ),
    );
  }
}
