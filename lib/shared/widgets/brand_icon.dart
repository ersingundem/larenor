import 'package:flutter/cupertino.dart';

import '../../features/settings/data/app_service.dart';

/// The vendored real logo mark for each [AppService] that has one, under
/// `assets/brand_icons/`. Services without a reliably-sourced official
/// square mark (e.g. Keenetic) simply aren't in this map, and callers
/// should fall back to [IconBadge] with a generic glyph for those.
const _brandIconAssets = <AppService, String>{
  AppService.jellyfin: 'assets/brand_icons/jellyfin.png',
  AppService.jellyseerr: 'assets/brand_icons/jellyseerr.png',
  AppService.sonarr: 'assets/brand_icons/sonarr.png',
  AppService.radarr: 'assets/brand_icons/radarr.png',
  AppService.lidarr: 'assets/brand_icons/lidarr.png',
  AppService.readarr: 'assets/brand_icons/readarr.png',
  AppService.bazarr: 'assets/brand_icons/bazarr.png',
  AppService.prowlarr: 'assets/brand_icons/prowlarr.png',
  AppService.qbittorrent: 'assets/brand_icons/qbittorrent.png',
  AppService.proxmox: 'assets/brand_icons/proxmox.png',
};

/// Whether [service] has a vendored real logo available via [BrandIcon].
bool hasBrandIcon(AppService service) => _brandIconAssets.containsKey(service);

/// A small rounded-square badge holding a service's own real logo mark,
/// rendered on a neutral light backdrop (rather than [IconBadge]'s solid
/// brand-color square) since these logos already carry their own color.
/// Same ~29x29 rounded-square silhouette as [IconBadge] so the two sit
/// naturally side by side in the same list.
class BrandIcon extends StatelessWidget {
  const BrandIcon({super.key, required this.service, this.size = 29});

  final AppService service;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = _brandIconAssets[service];
    assert(asset != null, 'No vendored brand icon for $service');
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      padding: EdgeInsets.all(size * 0.14),
      child: asset == null ? null : Image.asset(asset, fit: BoxFit.contain),
    );
  }
}
