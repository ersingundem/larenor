import 'package:flutter/widgets.dart';

import '../../domain/tile_config.dart';
import 'camera_tile.dart';
import 'climate_tile.dart';
import 'entity_tile.dart';
import 'history_tile.dart';
import 'media_player_tile.dart';
import 'scene_tile.dart';
import 'weather_tile.dart';
import 'webview_tile.dart';

Widget buildTileContent(TileConfig tile) {
  return switch (tile.type) {
    TileType.entity => EntityTile(tile: tile),
    TileType.webview => WebviewTile(tile: tile),
    TileType.scene => SceneTile(tile: tile),
    TileType.mediaPlayer => MediaPlayerTile(tile: tile),
    TileType.climate => ClimateTile(tile: tile),
    TileType.weather => WeatherTile(tile: tile),
    TileType.history => HistoryTile(tile: tile),
    TileType.camera => CameraTile(tile: tile),
  };
}
