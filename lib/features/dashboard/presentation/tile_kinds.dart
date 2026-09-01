import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../settings/data/app_service.dart';
import '../domain/tile_config.dart';

/// Static metadata for one tile type — label plus the icon/colour used
/// wherever a tile kind needs to be named in the UI.
class TileKindInfo {
  const TileKindInfo(
    this.label,
    this.icon,
    this.color, {
    this.domainFilter,
    this.width = 2,
    this.height = 2,
  });

  final String label;
  final IconData icon;
  final Color color;
  final String? domainFilter;
  final int width;
  final int height;
}

/// The 7 tile types tied to a single Home Assistant entity, picked via
/// [EntityPickerScreen] after the type itself is chosen.
const tileKinds = {
  TileType.entity: TileKindInfo(
    'Entity card',
    CupertinoIcons.square_grid_2x2,
    CupertinoColors.systemGrey,
  ),
  TileType.scene: TileKindInfo(
    'Scene button',
    CupertinoIcons.wand_stars,
    CupertinoColors.systemPurple,
    domainFilter: 'scene',
  ),
  TileType.mediaPlayer: TileKindInfo(
    'Media player',
    CupertinoIcons.play_circle,
    CupertinoColors.systemPurple,
    domainFilter: 'media_player',
    width: 3,
    height: 3,
  ),
  TileType.climate: TileKindInfo(
    'Climate',
    CupertinoIcons.thermometer,
    CupertinoColors.systemOrange,
    domainFilter: 'climate',
    width: 3,
    height: 3,
  ),
  TileType.weather: TileKindInfo(
    'Weather',
    CupertinoIcons.cloud,
    CupertinoColors.systemBlue,
    domainFilter: 'weather',
    width: 4,
    height: 3,
  ),
  TileType.history: TileKindInfo(
    'History graph',
    CupertinoIcons.graph_circle,
    CupertinoColors.systemTeal,
    width: 4,
    height: 3,
  ),
  TileType.camera: TileKindInfo(
    'Camera',
    CupertinoIcons.videocam,
    CupertinoColors.systemIndigo,
    domainFilter: 'camera',
    width: 3,
    height: 3,
  ),
};

/// The 11 external-service summary tiles — unlike everything in
/// [tileKinds], these aren't tied to a Home Assistant entity, they read
/// from that service's own app-wide connection (configured once via
/// Settings → Manage Integrations), so adding one needs no entity picker
/// and no per-tile setup dialog at all.
const serviceTileKinds = {
  TileType.jellyfin: TileKindInfo(
    'Jellyfin',
    CupertinoIcons.play_rectangle,
    CupertinoColors.systemPurple,
    width: 3,
    height: 2,
  ),
  TileType.jellyseerr: TileKindInfo(
    'Jellyseerr',
    CupertinoIcons.search,
    CupertinoColors.systemBlue,
    width: 3,
    height: 2,
  ),
  TileType.sonarr: TileKindInfo(
    'Sonarr',
    CupertinoIcons.tv,
    CupertinoColors.systemIndigo,
    width: 3,
    height: 2,
  ),
  TileType.radarr: TileKindInfo(
    'Radarr',
    CupertinoIcons.film,
    CupertinoColors.systemYellow,
    width: 3,
    height: 2,
  ),
  TileType.lidarr: TileKindInfo(
    'Lidarr',
    CupertinoIcons.music_note,
    CupertinoColors.systemGreen,
    width: 3,
    height: 2,
  ),
  TileType.readarr: TileKindInfo(
    'Readarr',
    CupertinoIcons.book,
    CupertinoColors.systemOrange,
    width: 3,
    height: 2,
  ),
  TileType.bazarr: TileKindInfo(
    'Bazarr',
    CupertinoIcons.captions_bubble,
    CupertinoColors.systemTeal,
    width: 3,
    height: 2,
  ),
  TileType.prowlarr: TileKindInfo(
    'Prowlarr',
    CupertinoIcons.dot_radiowaves_left_right,
    CupertinoColors.systemOrange,
    width: 3,
    height: 2,
  ),
  TileType.qbittorrent: TileKindInfo(
    'qBittorrent',
    CupertinoIcons.arrow_down_circle,
    CupertinoColors.systemBlue,
    width: 3,
    height: 2,
  ),
  TileType.proxmox: TileKindInfo(
    'Proxmox',
    CupertinoIcons.square_stack_3d_up,
    CupertinoColors.systemOrange,
    width: 3,
    height: 2,
  ),
  TileType.keenetic: TileKindInfo(
    'Keenetic',
    CupertinoIcons.wifi,
    CupertinoColors.systemGreen,
    width: 3,
    height: 2,
  ),
};

/// Which summary tile represents each optional service, so the dashboard's
/// Services section can be built straight from [enabledServicesProvider]
/// without any per-tile configuration.
const serviceTileTypes = {
  AppService.jellyfin: TileType.jellyfin,
  AppService.jellyseerr: TileType.jellyseerr,
  AppService.sonarr: TileType.sonarr,
  AppService.radarr: TileType.radarr,
  AppService.lidarr: TileType.lidarr,
  AppService.readarr: TileType.readarr,
  AppService.bazarr: TileType.bazarr,
  AppService.prowlarr: TileType.prowlarr,
  AppService.qbittorrent: TileType.qbittorrent,
  AppService.proxmox: TileType.proxmox,
  AppService.keenetic: TileType.keenetic,
};

const webviewTileKind = TileKindInfo(
  'Fullscreen website',
  CupertinoIcons.globe,
  CupertinoColors.systemBlue,
  width: 4,
  height: 4,
);

/// Localized label for a [TileType], since [TileKindInfo.label] lives in a
/// `const` map and can't call [AppLocalizations.of] itself.
String tileTypeLabel(BuildContext context, TileType type) {
  final l10n = AppLocalizations.of(context);
  switch (type) {
    case TileType.entity:
      return l10n.dashboardTileEntity;
    case TileType.scene:
      return l10n.dashboardTileScene;
    case TileType.mediaPlayer:
      return l10n.dashboardTileMediaPlayer;
    case TileType.climate:
      return l10n.dashboardTileClimate;
    case TileType.weather:
      return l10n.dashboardTileWeather;
    case TileType.history:
      return l10n.dashboardTileHistory;
    case TileType.camera:
      return l10n.dashboardTileCamera;
    case TileType.jellyfin:
      return l10n.dashboardTileJellyfin;
    case TileType.jellyseerr:
      return l10n.dashboardTileJellyseerr;
    case TileType.sonarr:
      return l10n.dashboardTileSonarr;
    case TileType.radarr:
      return l10n.dashboardTileRadarr;
    case TileType.lidarr:
      return l10n.dashboardTileLidarr;
    case TileType.readarr:
      return l10n.dashboardTileReadarr;
    case TileType.bazarr:
      return l10n.dashboardTileBazarr;
    case TileType.prowlarr:
      return l10n.dashboardTileProwlarr;
    case TileType.qbittorrent:
      return l10n.dashboardTileQbittorrent;
    case TileType.proxmox:
      return l10n.dashboardTileProxmox;
    case TileType.keenetic:
      return l10n.dashboardTileKeenetic;
    case TileType.webview:
      return l10n.dashboardTileWebview;
  }
}
