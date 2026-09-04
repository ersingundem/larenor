import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../keenetic/presentation/keenetic_home_screen.dart';
import '../../media/arr/presentation/lidarr_screen.dart';
import '../../media/arr/presentation/radarr_screen.dart';
import '../../media/arr/presentation/readarr_screen.dart';
import '../../media/arr/presentation/sonarr_screen.dart';
import '../../media/bazarr/presentation/bazarr_home_screen.dart';
import '../../media/jellyfin/presentation/jellyfin_home_screen.dart';
import '../../media/jellyseerr/presentation/jellyseerr_home_screen.dart';
import '../../media/prowlarr/presentation/prowlarr_indexers_screen.dart';
import '../../media/qbittorrent/presentation/qbittorrent_torrents_screen.dart';
import '../../proxmox/presentation/proxmox_nodes_screen.dart';
import '../data/app_service.dart';
import '../providers/enabled_services_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/brand_icon.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../../../shared/widgets/integration_health_status.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';

/// Every optional service in one place: toggle it on/off and inspect the last
/// observed data read. Disabling a service keeps its saved credentials.
class ManageIntegrationsScreen extends ConsumerWidget {
  const ManageIntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final enabled = ref.watch(enabledServicesProvider).value ?? const {};

    void toggle(AppService service, bool value) =>
        ref.read(enabledServicesProvider.notifier).setEnabled(service, value);

    return AppPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.settingsManageIntegrations),
          ),
          SliverSafeArea(
            top: false,
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 16),
                SettingsSection(
                  header: Text(l10n.settingsSectionMediaServices),
                  children: [
                    _ServiceRow(
                      icon: CupertinoIcons.play_rectangle,
                      color: CupertinoColors.systemPurple,
                      service: AppService.jellyfin,
                      title: 'Jellyfin',
                      enabled: enabled.contains(AppService.jellyfin),
                      onToggle: (v) => toggle(AppService.jellyfin, v),
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const JellyfinHomeScreen(),
                        ),
                      ),
                    ),
                    _ServiceRow(
                      icon: CupertinoIcons.search,
                      color: CupertinoColors.systemBlue,
                      service: AppService.jellyseerr,
                      title: 'Jellyseerr',
                      enabled: enabled.contains(AppService.jellyseerr),
                      onToggle: (v) => toggle(AppService.jellyseerr, v),
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const JellyseerrHomeScreen(),
                        ),
                      ),
                    ),
                    _ServiceRow(
                      icon: CupertinoIcons.tv,
                      color: CupertinoColors.systemIndigo,
                      service: AppService.sonarr,
                      title: 'Sonarr',
                      enabled: enabled.contains(AppService.sonarr),
                      onToggle: (v) => toggle(AppService.sonarr, v),
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const SonarrScreen(),
                        ),
                      ),
                    ),
                    _ServiceRow(
                      icon: CupertinoIcons.film,
                      color: CupertinoColors.systemYellow,
                      service: AppService.radarr,
                      title: 'Radarr',
                      enabled: enabled.contains(AppService.radarr),
                      onToggle: (v) => toggle(AppService.radarr, v),
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const RadarrScreen(),
                        ),
                      ),
                    ),
                    _ServiceRow(
                      icon: CupertinoIcons.music_note,
                      color: CupertinoColors.systemGreen,
                      service: AppService.lidarr,
                      title: 'Lidarr',
                      enabled: enabled.contains(AppService.lidarr),
                      onToggle: (v) => toggle(AppService.lidarr, v),
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const LidarrScreen(),
                        ),
                      ),
                    ),
                    _ServiceRow(
                      icon: CupertinoIcons.book,
                      color: CupertinoColors.systemOrange,
                      service: AppService.readarr,
                      title: 'Readarr',
                      enabled: enabled.contains(AppService.readarr),
                      onToggle: (v) => toggle(AppService.readarr, v),
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const ReadarrScreen(),
                        ),
                      ),
                    ),
                    _ServiceRow(
                      icon: CupertinoIcons.captions_bubble,
                      color: CupertinoColors.systemTeal,
                      service: AppService.bazarr,
                      title: 'Bazarr',
                      enabled: enabled.contains(AppService.bazarr),
                      onToggle: (v) => toggle(AppService.bazarr, v),
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const BazarrHomeScreen(),
                        ),
                      ),
                    ),
                    _ServiceRow(
                      icon: CupertinoIcons.dot_radiowaves_left_right,
                      color: CupertinoColors.systemOrange,
                      service: AppService.prowlarr,
                      title: 'Prowlarr',
                      enabled: enabled.contains(AppService.prowlarr),
                      onToggle: (v) => toggle(AppService.prowlarr, v),
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const ProwlarrIndexersScreen(),
                        ),
                      ),
                    ),
                    _ServiceRow(
                      icon: CupertinoIcons.arrow_down_circle,
                      color: CupertinoColors.systemBlue,
                      service: AppService.qbittorrent,
                      title: 'qBittorrent',
                      enabled: enabled.contains(AppService.qbittorrent),
                      onToggle: (v) => toggle(AppService.qbittorrent, v),
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const QbittorrentTorrentsScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
                SettingsSection(
                  header: Text(l10n.settingsSectionInfrastructure),
                  children: [
                    _ServiceRow(
                      icon: CupertinoIcons.square_stack_3d_up,
                      color: CupertinoColors.systemOrange,
                      service: AppService.proxmox,
                      title: 'Proxmox',
                      enabled: enabled.contains(AppService.proxmox),
                      onToggle: (v) => toggle(AppService.proxmox, v),
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const ProxmoxNodesScreen(),
                        ),
                      ),
                    ),
                    _ServiceRow(
                      icon: CupertinoIcons.wifi,
                      color: CupertinoColors.systemGreen,
                      service: AppService.keenetic,
                      title: 'Keenetic',
                      enabled: enabled.contains(AppService.keenetic),
                      onToggle: (v) => toggle(AppService.keenetic, v),
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const KeeneticHomeScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.enabled,
    required this.onToggle,
    required this.onTap,
    required this.service,
  });

  final IconData icon;
  final Color color;
  final String title;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  /// When a real vendored logo exists for this service, that logo is shown
  /// via [BrandIcon] instead of the generic [icon]/[color] pair.
  final AppService service;

  @override
  Widget build(BuildContext context) {
    final service = this.service;
    return CupertinoListTile(
      leading: hasBrandIcon(service)
          ? BrandIcon(service: service)
          : IconBadge(icon: icon, color: color),
      title: Text(title),
      subtitle: SavedServiceHealthStatus(service: service),
      trailing: CupertinoSwitch(value: enabled, onChanged: onToggle),
      onTap: onTap,
    );
  }
}
