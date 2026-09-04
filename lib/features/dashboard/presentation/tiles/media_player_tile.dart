import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/icon_sizes.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';

class MediaPlayerTile extends ConsumerWidget {
  const MediaPlayerTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entity = ref.watch(entitiesProvider).value?[tile.entityId];
    if (entity == null) {
      return ColoredBox(
        color: CupertinoColors.systemGrey5.resolveFrom(context),
        child: Center(
          child: Text(AppLocalizations.of(context).commonUnknownEntity),
        ),
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
        padding: Insets.tile,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              entity.friendlyName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.tileTitle,
            ),
            if (title != null)
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.tileSubtitle,
              ),
            if (artist != null)
              Text(
                artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppText.tileSubtitle.fontSize,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _TransportButton(
                  icon: CupertinoIcons.backward_fill,
                  onPressed: () => callService('media_previous_track'),
                ),
                _TransportButton(
                  icon: isPlaying
                      ? CupertinoIcons.pause_fill
                      : CupertinoIcons.play_fill,
                  size: IconSizes.control,
                  onPressed: () =>
                      callService(isPlaying ? 'media_pause' : 'media_play'),
                ),
                _TransportButton(
                  icon: CupertinoIcons.forward_fill,
                  onPressed: () => callService('media_next_track'),
                ),
              ],
            ),
            if (volume != null)
              Row(
                children: [
                  const Icon(CupertinoIcons.speaker_2, size: IconSizes.caption),
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

/// A transport control sized to the 44pt minimum tap target. These were
/// bare 22–28pt icons in a `GestureDetector`, which takes exactly its
/// child's hit rect — the cell has plenty of room for a proper target.
class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.icon,
    required this.onPressed,
    this.size = 22,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => CupertinoButton(
    padding: EdgeInsets.zero,
    minimumSize: const Size.square(IconSizes.minTapTarget),
    onPressed: onPressed,
    child: Icon(icon, size: size),
  );
}
