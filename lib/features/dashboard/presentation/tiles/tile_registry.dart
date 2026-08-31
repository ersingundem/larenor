import 'package:flutter/widgets.dart';

import '../../domain/tile_config.dart';
import 'bazarr_tile.dart';
import 'camera_tile.dart';
import 'climate_tile.dart';
import 'entity_tile.dart';
import 'history_tile.dart';
import 'jellyfin_tile.dart';
import 'jellyseerr_tile.dart';
import 'keenetic_tile.dart';
import 'lidarr_tile.dart';
import 'media_player_tile.dart';
import 'prowlarr_tile.dart';
import 'proxmox_tile.dart';
import 'qbittorrent_tile.dart';
import 'radarr_tile.dart';
import 'readarr_tile.dart';
import 'scene_tile.dart';
import 'sonarr_tile.dart';
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
    TileType.jellyfin => JellyfinTile(tile: tile),
    TileType.jellyseerr => JellyseerrTile(tile: tile),
    TileType.sonarr => SonarrTile(tile: tile),
    TileType.radarr => RadarrTile(tile: tile),
    TileType.lidarr => LidarrTile(tile: tile),
    TileType.readarr => ReadarrTile(tile: tile),
    TileType.bazarr => BazarrTile(tile: tile),
    TileType.prowlarr => ProwlarrTile(tile: tile),
    TileType.qbittorrent => QbittorrentTile(tile: tile),
    TileType.proxmox => ProxmoxTile(tile: tile),
    TileType.keenetic => KeeneticTile(tile: tile),
  };
}
