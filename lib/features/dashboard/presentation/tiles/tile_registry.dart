import 'package:flutter/material.dart';

import '../../domain/tile_config.dart';
import 'entity_tile.dart';
import 'webview_tile.dart';

Widget buildTileContent(TileConfig tile) {
  return switch (tile.type) {
    TileType.entity => EntityTile(tile: tile),
    TileType.webview => WebviewTile(tile: tile),
  };
}
