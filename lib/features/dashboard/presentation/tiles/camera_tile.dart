import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/camera_snapshot.dart';
import '../../domain/tile_config.dart';

class CameraTile extends StatelessWidget {
  const CameraTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context) {
    final entityId = tile.entityId;
    if (entityId == null) {
      return ColoredBox(
        color: CupertinoColors.systemGrey5.resolveFrom(context),
        child: Center(
          child: Text(AppLocalizations.of(context).commonUnknownEntity),
        ),
      );
    }
    return CameraSnapshot(entityId: entityId);
  }
}
