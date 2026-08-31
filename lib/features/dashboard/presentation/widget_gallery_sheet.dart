import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/icon_badge.dart';
import '../domain/tile_config.dart';
import 'tile_kinds.dart';
import 'tiles/tile_registry.dart';

final List<MapEntry<TileType, TileKindInfo>> _galleryEntries = [
  ...tileKinds.entries,
  ...serviceTileKinds.entries,
  const MapEntry(TileType.webview, webviewTileKind),
];

/// A non-modal panel sliding up from the bottom of the dashboard, listing
/// every addable tile type as a draggable preview card — unlike a
/// [showCupertinoModalPopup] sheet, this has no barrier, so the dashboard
/// grid underneath stays live and hit-testable while a card is being
/// dragged onto it, the way iOS's own widget gallery works.
class WidgetGallery extends StatelessWidget {
  const WidgetGallery({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.5,
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withValues(alpha: 0.2),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Add Widget',
                    style: CupertinoTheme.of(context)
                        .textTheme
                        .navTitleTextStyle,
                  ),
                ),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: onClose,
                  child: const Icon(CupertinoIcons.xmark_circle_fill),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Long-press a widget, then drag it onto your dashboard.',
                style: TextStyle(
                  fontSize: 12,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.6,
              ),
              itemCount: _galleryEntries.length,
              itemBuilder: (context, index) {
                final entry = _galleryEntries[index];
                return _GalleryCard(type: entry.key, kind: entry.value);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryCard extends StatelessWidget {
  const _GalleryCard({required this.type, required this.kind});

  final TileType type;
  final TileKindInfo kind;

  bool get _isServiceWidget => serviceTileKinds.containsKey(type);

  @override
  Widget build(BuildContext context) {
    final card = _buildCard(context);

    return LongPressDraggable<TileType>(
      data: type,
      feedback: SizedBox(
        width: 150,
        height: 100,
        child: Opacity(
          opacity: 0.9,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: CupertinoColors.black.withValues(alpha: 0.3),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: card,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: card),
      child: card,
    );
  }

  Widget _buildCard(BuildContext context) {
    final preview = _isServiceWidget
        ? IgnorePointer(
            child: buildTileContent(
              TileConfig(
                id: 'preview-${type.name}',
                type: type,
                x: 0,
                y: 0,
                width: kind.width,
                height: kind.height,
              ),
            ),
          )
        : ColoredBox(
            color: CupertinoColors.tertiarySystemGroupedBackground.resolveFrom(
              context,
            ),
            child: Center(
              child: IconBadge(icon: kind.icon, color: kind.color),
            ),
          );

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: CupertinoColors.systemBackground.resolveFrom(context),
          border: Border.all(
            color: CupertinoColors.separator.resolveFrom(context),
          ),
        ),
        child: Column(
          children: [
            Expanded(child: preview),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 4),
              color: CupertinoColors.secondarySystemGroupedBackground
                  .resolveFrom(context),
              child: Text(
                kind.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
