import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';

class MediaPlayerTile extends ConsumerWidget {
  const MediaPlayerTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entity = ref.watch(entitiesProvider).value?[tile.entityId];
    if (entity == null) {
      return const ColoredBox(
        color: CupertinoColors.systemGrey5,
        child: Center(child: Text('Unknown entity')),
      );
    }

    final isPlaying = entity.state == 'playing';
    final title = entity.attributes['media_title'] as String?;
    final artist = entity.attributes['media_artist'] as String?;
    final volume = (entity.attributes['volume_level'] as num?)?.toDouble();

    void callService(String service, [Map<String, dynamic>? data]) {
      ref
          .read(haRestClientProvider)
          ?.callService(
            'media_player',
            service,
            entityId: entity.entityId,
            serviceData: data,
          );
    }

    return ColoredBox(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              entity.friendlyName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            if (title != null)
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            if (artist != null)
              Text(
                artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                GestureDetector(
                  onTap: () => callService('media_previous_track'),
                  child: const Icon(CupertinoIcons.backward_fill, size: 22),
                ),
                GestureDetector(
                  onTap: () =>
                      callService(isPlaying ? 'media_pause' : 'media_play'),
                  child: Icon(
                    isPlaying
                        ? CupertinoIcons.pause_fill
                        : CupertinoIcons.play_fill,
                    size: 28,
                  ),
                ),
                GestureDetector(
                  onTap: () => callService('media_next_track'),
                  child: const Icon(CupertinoIcons.forward_fill, size: 22),
                ),
              ],
            ),
            if (volume != null)
              Row(
                children: [
                  const Icon(CupertinoIcons.speaker_2, size: 14),
                  Expanded(
                    child: CupertinoSlider(
                      value: volume.clamp(0.0, 1.0),
                      onChanged: (value) =>
                          callService('volume_set', {'volume_level': value}),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
