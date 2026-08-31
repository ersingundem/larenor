import 'package:flutter/cupertino.dart';

import '../../../../shared/widgets/camera_snapshot.dart';
import '../../domain/tile_config.dart';

class CameraTile extends StatelessWidget {
  const CameraTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context) {
    final entityId = tile.entityId;
    if (entityId == null) {
      return const ColoredBox(
        color: CupertinoColors.systemGrey5,
        child: Center(child: Text('Unknown entity')),
      );
    }
    return CameraSnapshot(entityId: entityId);
  }
}
