import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../keenetic/presentation/keenetic_home_screen.dart';
import '../../keenetic/providers/keenetic_providers.dart';
import '../../media/arr/presentation/lidarr_screen.dart';
import '../../media/arr/presentation/radarr_screen.dart';
import '../../media/arr/presentation/readarr_screen.dart';
import '../../media/arr/presentation/sonarr_screen.dart';
import '../../media/arr/providers/lidarr_providers.dart';
import '../../media/arr/providers/radarr_providers.dart';
import '../../media/arr/providers/readarr_providers.dart';
import '../../media/arr/providers/sonarr_providers.dart';
import '../../media/bazarr/presentation/bazarr_home_screen.dart';
import '../../media/bazarr/providers/bazarr_providers.dart';
import '../../media/jellyfin/presentation/jellyfin_home_screen.dart';
import '../../media/jellyfin/providers/jellyfin_providers.dart';
import '../../media/jellyseerr/presentation/jellyseerr_home_screen.dart';
import '../../media/jellyseerr/providers/jellyseerr_providers.dart';
import '../../media/prowlarr/presentation/prowlarr_indexers_screen.dart';
import '../../media/prowlarr/providers/prowlarr_providers.dart';
import '../../media/qbittorrent/presentation/qbittorrent_torrents_screen.dart';
import '../../media/qbittorrent/providers/qbittorrent_providers.dart';
import '../../proxmox/presentation/proxmox_nodes_screen.dart';
import '../../proxmox/providers/proxmox_providers.dart';
import '../data/app_service.dart';
import '../providers/enabled_services_providers.dart';
import '../../../shared/widgets/icon_badge.dart';

/// Every optional service in one place: toggle it on/off, and see at a
/// glance whether it's actually connected. Turning a service off only
/// hides it from the main Settings screen — it doesn't clear saved
/// credentials, so turning it back on doesn't require reconnecting.
class ManageIntegrationsScreen extends ConsumerWidget {
  const ManageIntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(enabledServicesProvider).value ?? const {};

    void toggle(AppService service, bool value) =>
        ref.read(enabledServicesProvider.notifier).setEnabled(service, value);

    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          const CupertinoSliverNavigationBar(
            largeTitle: Text('Manage Integrations'),
          ),
          SliverSafeArea(
            top: false,
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  header: const Text('MEDIA SERVICES'),
                  children: [
                    _ServiceRow(
                      icon: CupertinoIcons.play_rectangle,
                      color: CupertinoColors.systemPurple,
                      title: 'Jellyfin',
                      connected:
                          ref.watch(jellyfinConnectionProvider).value != null,
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
                      title: 'Jellyseerr',
                      connected:
                          ref.watch(jellyseerrConnectionProvider).value != null,
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
                      title: 'Sonarr',
                      connected:
                          ref.watch(sonarrConnectionProvider).value != null,
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
                      title: 'Radarr',
                      connected:
                          ref.watch(radarrConnectionProvider).value != null,
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
                      title: 'Lidarr',
                      connected:
                          ref.watch(lidarrConnectionProvider).value != null,
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
                      title: 'Readarr',
                      connected:
                          ref.watch(readarrConnectionProvider).value != null,
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
                      title: 'Bazarr',
                      connected:
                          ref.watch(bazarrConnectionProvider).value != null,
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
                      title: 'Prowlarr',
                      connected:
                          ref.watch(prowlarrConnectionProvider).value != null,
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
                      title: 'qBittorrent',
                      connected:
                          ref.watch(qbittorrentConnectionProvider).value !=
                          null,
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
                CupertinoListSection.insetGrouped(
                  header: const Text('INFRASTRUCTURE'),
                  children: [
                    _ServiceRow(
                      icon: CupertinoIcons.square_stack_3d_up,
                      color: CupertinoColors.systemOrange,
                      title: 'Proxmox',
                      connected:
                          ref.watch(proxmoxConnectionProvider).value != null,
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
                      title: 'Keenetic',
                      connected:
                          ref.watch(keeneticConnectionProvider).value != null,
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
    required this.connected,
    required this.enabled,
    required this.onToggle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final bool connected;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      leading: IconBadge(icon: icon, color: color),
      title: Text(title),
      subtitle: Text(connected ? 'Connected' : 'Not connected'),
      trailing: CupertinoSwitch(value: enabled, onChanged: onToggle),
      onTap: onTap,
    );
  }
}
