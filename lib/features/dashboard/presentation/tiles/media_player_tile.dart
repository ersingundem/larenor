import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/icon_sizes.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';
import 'tile_action_support.dart';

class MediaPlayerTile extends ConsumerStatefulWidget {
  const MediaPlayerTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  ConsumerState<MediaPlayerTile> createState() => _MediaPlayerTileState();
}

class _MediaPlayerTileState extends ConsumerState<MediaPlayerTile>
    with TileActionSupport<MediaPlayerTile> {
  double? _draftVolume;
  int? _volumeGestureGeneration;

  @override
  String? get actionEntityId => widget.tile.entityId;
  @override
  void resetTileDrafts() {
    _draftVolume = null;
    _volumeGestureGeneration = null;
  }

  @override
  void didUpdateWidget(covariant MediaPlayerTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tile.entityId != actionEntityId) resetTileAction();
  }

  @override
  Widget build(BuildContext context) {
    watchTileActions();
    final entity = ref.watch(entitiesProvider).value?[actionEntityId];
    final l10n = AppLocalizations.of(context);
    if (entity == null || entity.domain != 'media_player') {
      return ColoredBox(
        color: CupertinoColors.systemGrey5.resolveFrom(context),
        child: Center(child: Text(l10n.commonUnknownEntity)),
      );
    }
    final isPlaying = entity.state == 'playing';
    final title = entity.attributes['media_title'];
    final artist = entity.attributes['media_artist'];
    final volume = finiteTileNumber(entity.attributes['volume_level']);
    final buttons = <Widget>[];
    void button(
      IconData icon,
      String service,
      int feature,
      String label, {
      double size = 22,
    }) {
      if (!tileServiceAvailable(entity, service, feature: feature)) return;
      buttons.add(
        CupertinoButton(
          key: ValueKey('media-tile-$service'),
          padding: EdgeInsets.zero,
          minimumSize: const Size.square(IconSizes.minTapTarget),
          onPressed: tileActionBusy
              ? null
              : () => executeTileAction(
                  'media_player',
                  service,
                  feature: feature,
                ),
          child: Icon(icon, size: size, semanticLabel: label),
        ),
      );
    }

    button(
      CupertinoIcons.backward_fill,
      'media_previous_track',
      16,
      l10n.entityControlPrevious,
    );
    button(
      isPlaying ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
      isPlaying ? 'media_pause' : 'media_play',
      isPlaying ? 1 : 16384,
      isPlaying ? l10n.entityControlPause : l10n.mediaActionPlay,
      size: IconSizes.control,
    );
    button(
      CupertinoIcons.forward_fill,
      'media_next_track',
      32,
      l10n.commonNext,
    );
    final canSetVolume =
        volume != null &&
        tileServiceAvailable(entity, 'volume_set', feature: 4);

    return ColoredBox(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      child: Padding(
        padding: Insets.tile,
        child: TileContentViewport(
          builder: (context, availableHeight) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                entity.friendlyName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.tileTitle,
              ),
              if (title is String)
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.tileSubtitle,
                ),
              if (artist is String)
                Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.tileSubtitle.copyWith(
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              if (buttons.isNotEmpty)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: buttons,
                ),
              if (canSetVolume)
                Row(
                  children: [
                    const Icon(
                      CupertinoIcons.speaker_2,
                      size: IconSizes.caption,
                    ),
                    Expanded(
                      child: Semantics(
                        label: l10n.entityControlVolume,
                        child: CupertinoSlider(
                          key: ValueKey(
                            'media-tile-volume-$tileActionGeneration',
                          ),
                          value: (_draftVolume ?? volume).clamp(0.0, 1.0),
                          divisions: 100,
                          onChangeStart: tileActionBusy
                              ? null
                              : (_) => _volumeGestureGeneration =
                                    tileActionGeneration,
                          onChanged: tileActionBusy
                              ? null
                              : (value) {
                                  if (!mounted ||
                                      !value.isFinite ||
                                      _volumeGestureGeneration !=
                                          tileActionGeneration) {
                                    return;
                                  }
                                  setState(
                                    () => _draftVolume =
                                        (value.clamp(0.0, 1.0) * 100).round() /
                                        100,
                                  );
                                },
                          onChangeEnd: tileActionBusy
                              ? null
                              : (value) {
                                  if (!mounted ||
                                      !value.isFinite ||
                                      _volumeGestureGeneration !=
                                          tileActionGeneration) {
                                    return;
                                  }
                                  final selected =
                                      (value.clamp(0.0, 1.0) * 100).round() /
                                      100;
                                  setState(resetTileDrafts);
                                  if ((selected - volume).abs() < 0.0001) {
                                    return;
                                  }
                                  executeTileAction(
                                    'media_player',
                                    'volume_set',
                                    feature: 4,
                                    serviceData: {'volume_level': selected},
                                  );
                                },
                        ),
                      ),
                    ),
                  ],
                ),
              TileActionFeedback(
                entityId: actionEntityId,
                error: tileActionError,
                busy: tileActionBusy,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
