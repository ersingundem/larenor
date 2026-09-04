import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../keenetic/presentation/keenetic_home_screen.dart';
import '../../../keenetic/providers/keenetic_providers.dart';
import '../../../media/arr/presentation/lidarr_screen.dart';
import '../../../media/arr/presentation/radarr_screen.dart';
import '../../../media/arr/presentation/readarr_screen.dart';
import '../../../media/arr/presentation/sonarr_screen.dart';
import '../../../media/arr/providers/lidarr_providers.dart';
import '../../../media/arr/providers/radarr_providers.dart';
import '../../../media/arr/providers/readarr_providers.dart';
import '../../../media/arr/providers/sonarr_providers.dart';
import '../../../media/bazarr/presentation/bazarr_home_screen.dart';
import '../../../media/bazarr/providers/bazarr_providers.dart';
import '../../../media/hub/presentation/media_hub_screen.dart';
import '../../../media/jellyfin/presentation/jellyfin_home_screen.dart';
import '../../../media/jellyfin/providers/jellyfin_providers.dart';
import '../../../media/jellyseerr/presentation/jellyseerr_home_screen.dart';
import '../../../media/jellyseerr/providers/jellyseerr_providers.dart';
import '../../../media/prowlarr/presentation/prowlarr_indexers_screen.dart';
import '../../../media/prowlarr/providers/prowlarr_providers.dart';
import '../../../media/qbittorrent/presentation/qbittorrent_torrents_screen.dart';
import '../../../media/qbittorrent/providers/qbittorrent_providers.dart';
import '../../../proxmox/presentation/proxmox_nodes_screen.dart';
import '../../../proxmox/providers/proxmox_providers.dart';
import '../../data/app_service.dart';
import '../../providers/enabled_services_providers.dart';
import '../manage_integrations_screen.dart';
import 'settings_nav_row.dart';

class IntegrationsPane extends ConsumerWidget {
  const IntegrationsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final enabledServices =
        ref.watch(enabledServicesProvider).value ?? const {};

    bool active(AppService service, bool connected) =>
        enabledServices.contains(service) && connected;

    final rows = <SettingsNavRow>[
      if (active(
        AppService.jellyfin,
        ref.watch(jellyfinConnectionProvider).value != null,
      ))
        SettingsNavRow(
          icon: CupertinoIcons.play_rectangle,
          color: CupertinoColors.systemPurple,
          service: AppService.jellyfin,
          title: 'Jellyfin',
          builder: (_) => const JellyfinHomeScreen(),
        ),
      if (active(
        AppService.jellyseerr,
        ref.watch(jellyseerrConnectionProvider).value != null,
      ))
        SettingsNavRow(
          icon: CupertinoIcons.search,
          color: CupertinoColors.systemBlue,
          service: AppService.jellyseerr,
          title: 'Jellyseerr',
          builder: (_) => const JellyseerrHomeScreen(),
        ),
      if (active(
        AppService.sonarr,
        ref.watch(sonarrConnectionProvider).value != null,
      ))
        SettingsNavRow(
          icon: CupertinoIcons.tv,
          color: CupertinoColors.systemIndigo,
          service: AppService.sonarr,
          title: 'Sonarr',
          builder: (_) => const SonarrScreen(),
        ),
      if (active(
        AppService.radarr,
        ref.watch(radarrConnectionProvider).value != null,
      ))
        SettingsNavRow(
          icon: CupertinoIcons.film,
          color: CupertinoColors.systemYellow,
          service: AppService.radarr,
          title: 'Radarr',
          builder: (_) => const RadarrScreen(),
        ),
      if (active(
        AppService.lidarr,
        ref.watch(lidarrConnectionProvider).value != null,
      ))
        SettingsNavRow(
          icon: CupertinoIcons.music_note,
          color: CupertinoColors.systemGreen,
          service: AppService.lidarr,
          title: 'Lidarr',
          builder: (_) => const LidarrScreen(),
        ),
      if (active(
        AppService.readarr,
        ref.watch(readarrConnectionProvider).value != null,
      ))
        SettingsNavRow(
          icon: CupertinoIcons.book,
          color: CupertinoColors.systemOrange,
          service: AppService.readarr,
          title: 'Readarr',
          builder: (_) => const ReadarrScreen(),
        ),
      if (active(
        AppService.bazarr,
        ref.watch(bazarrConnectionProvider).value != null,
      ))
        SettingsNavRow(
          icon: CupertinoIcons.captions_bubble,
          color: CupertinoColors.systemTeal,
          service: AppService.bazarr,
          title: 'Bazarr',
          builder: (_) => const BazarrHomeScreen(),
        ),
      if (active(
        AppService.prowlarr,
        ref.watch(prowlarrConnectionProvider).value != null,
      ))
        SettingsNavRow(
          icon: CupertinoIcons.dot_radiowaves_left_right,
          color: CupertinoColors.systemOrange,
          service: AppService.prowlarr,
          title: 'Prowlarr',
          builder: (_) => const ProwlarrIndexersScreen(),
        ),
      if (active(
        AppService.qbittorrent,
        ref.watch(qbittorrentConnectionProvider).value != null,
      ))
        SettingsNavRow(
          icon: CupertinoIcons.arrow_down_circle,
          color: CupertinoColors.systemBlue,
          service: AppService.qbittorrent,
          title: 'qBittorrent',
          builder: (_) => const QbittorrentTorrentsScreen(),
        ),
      if (active(
        AppService.proxmox,
        ref.watch(proxmoxConnectionProvider).value != null,
      ))
        SettingsNavRow(
          icon: CupertinoIcons.square_stack_3d_up,
          color: CupertinoColors.systemOrange,
          service: AppService.proxmox,
          title: 'Proxmox',
          builder: (_) => const ProxmoxNodesScreen(),
        ),
      if (active(
        AppService.keenetic,
        ref.watch(keeneticConnectionProvider).value != null,
      ))
        SettingsNavRow(
          icon: CupertinoIcons.wifi,
          color: CupertinoColors.systemGreen,
          service: AppService.keenetic,
          title: 'Keenetic',
          builder: (_) => const KeeneticHomeScreen(),
        ),
    ];

    return SettingsPaneScaffold(
      title: l10n.settingsCategoryIntegrations,
      children: [
        CupertinoListSection.insetGrouped(
          footer: Text(l10n.settingsIntegrationsFooter),
          children: [
            // The unified hub leads, since it's the way into most of what
            // the rows below expose; those stay for the per-service tasks
            // that have no place in a browse-and-play layout.
            SettingsNavRow(
              icon: CupertinoIcons.play_rectangle,
              color: CupertinoColors.systemRed,
              title: l10n.mediaHubTitle,
              builder: (_) => const MediaHubScreen(),
            ),
            ...rows,
            SettingsNavRow(
              icon: CupertinoIcons.slider_horizontal_3,
              color: CupertinoColors.systemGrey,
              title: l10n.settingsManageIntegrations,
              builder: (_) => const ManageIntegrationsScreen(),
            ),
          ],
        ),
      ],
    );
  }
}
