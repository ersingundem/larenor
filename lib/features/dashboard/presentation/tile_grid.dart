import 'package:flutter/cupertino.dart';

import '../domain/tile_config.dart';

const double kGridCellSize = 110;
const int kGridMaxColumns = 12;

/// A free-form, drag-to-move / drag-to-resize grid of dashboard tiles.
///
/// Positions and sizes are expressed in grid cells (not pixels) so the
/// layout persists independently of screen size. There is no collision
/// avoidance in this MVP — tiles can be dragged to overlap, same as
/// freely arranging windows.
class TileGrid extends StatefulWidget {
  const TileGrid({
    super.key,
    required this.tiles,
    required this.tileBuilder,
    required this.editMode,
    required this.onTileChanged,
    required this.onTileRemoved,
  });

  final List<TileConfig> tiles;
  final Widget Function(BuildContext context, TileConfig tile) tileBuilder;
  final bool editMode;
  final ValueChanged<TileConfig> onTileChanged;
  final ValueChanged<String> onTileRemoved;

  @override
  State<TileGrid> createState() => _TileGridState();
}

class _TileGridState extends State<TileGrid> {
  String? _draggingId;
  Offset _dragAccumulator = Offset.zero;
  String? _resizingId;
  Offset _resizeAccumulator = Offset.zero;

  int get _rowCount {
    if (widget.tiles.isEmpty) return 4;
    final maxY = widget.tiles
        .map((t) => t.y + t.height)
        .reduce((a, b) => a > b ? a : b);
    return maxY + 2;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / kGridCellSize)
            .floor()
            .clamp(1, kGridMaxColumns);
        final cellSize = constraints.maxWidth / columns;
        final height = _rowCount * cellSize;

        return SingleChildScrollView(
          child: SizedBox(
            width: constraints.maxWidth,
            height: height,
            child: Stack(
              children: [
                for (final tile in widget.tiles)
                  _buildPositionedTile(tile, cellSize, columns),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPositionedTile(TileConfig tile, double cellSize, int columns) {
    final isDragging = _draggingId == tile.id;
    final isResizing = _resizingId == tile.id;

    var left = tile.x * cellSize;
    var top = tile.y * cellSize;
    var width = tile.width * cellSize;
    var height = tile.height * cellSize;

    if (isDragging) {
      left += _dragAccumulator.dx;
      top += _dragAccumulator.dy;
    }
    if (isResizing) {
      width = (width + _resizeAccumulator.dx).clamp(
        cellSize,
        columns * cellSize,
      );
      height = (height + _resizeAccumulator.dy).clamp(
        cellSize,
        double.infinity,
      );
    }

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: CupertinoColors.black.withValues(
                  alpha: isDragging || isResizing ? 0.25 : 0.08,
                ),
                blurRadius: isDragging || isResizing ? 16 : 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              children: [
                Positioned.fill(child: widget.tileBuilder(context, tile)),
                if (widget.editMode) _buildDragHandle(tile, cellSize),
                if (widget.editMode) _buildRemoveButton(tile),
                if (widget.editMode)
                  _buildResizeHandle(tile, cellSize, columns),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDragHandle(TileConfig tile, double cellSize) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => setState(() {
          _draggingId = tile.id;
          _dragAccumulator = Offset.zero;
        }),
        onPanUpdate: (details) =>
            setState(() => _dragAccumulator += details.delta),
        onPanEnd: (_) => _commitDrag(tile, cellSize),
        child: Container(
          height: 28,
          color: CupertinoColors.black.withValues(alpha: 0.35),
          alignment: Alignment.center,
          child: const Icon(
            CupertinoIcons.line_horizontal_3,
            size: 16,
            color: CupertinoColors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildRemoveButton(TileConfig tile) {
    return Positioned(
      top: 2,
      right: 2,
      child: GestureDetector(
        onTap: () => widget.onTileRemoved(tile.id),
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: CupertinoColors.black.withValues(alpha: 0.35),
          ),
          child: const Icon(
            CupertinoIcons.xmark,
            size: 14,
            color: CupertinoColors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildResizeHandle(TileConfig tile, double cellSize, int columns) {
    return Positioned(
      bottom: 0,
      right: 0,
      child: GestureDetector(
        onPanStart: (_) => setState(() {
          _resizingId = tile.id;
          _resizeAccumulator = Offset.zero;
        }),
        onPanUpdate: (details) =>
            setState(() => _resizeAccumulator += details.delta),
        onPanEnd: (_) => _commitResize(tile, cellSize, columns),
        child: Container(
          width: 24,
          height: 24,
          color: CupertinoColors.black.withValues(alpha: 0.35),
          child: const Icon(
            CupertinoIcons.resize,
            size: 14,
            color: CupertinoColors.white,
          ),
        ),
      ),
    );
  }

  void _commitDrag(TileConfig tile, double cellSize) {
    final deltaCellsX = (_dragAccumulator.dx / cellSize).round();
    final deltaCellsY = (_dragAccumulator.dy / cellSize).round();
    setState(() {
      _draggingId = null;
      _dragAccumulator = Offset.zero;
    });

    final newX = (tile.x + deltaCellsX).clamp(0, kGridMaxColumns - tile.width);
    final newY = (tile.y + deltaCellsY).clamp(0, 999);
    if (newX != tile.x || newY != tile.y) {
      widget.onTileChanged(tile.copyWith(x: newX, y: newY));
    }
  }

  void _commitResize(TileConfig tile, double cellSize, int columns) {
    final deltaCellsX = (_resizeAccumulator.dx / cellSize).round();
    final deltaCellsY = (_resizeAccumulator.dy / cellSize).round();
    setState(() {
      _resizingId = null;
      _resizeAccumulator = Offset.zero;
    });

    final newWidth = (tile.width + deltaCellsX).clamp(1, columns - tile.x);
    final newHeight = (tile.height + deltaCellsY).clamp(1, 999);
    if (newWidth != tile.width || newHeight != tile.height) {
      widget.onTileChanged(tile.copyWith(width: newWidth, height: newHeight));
    }
  }
}
