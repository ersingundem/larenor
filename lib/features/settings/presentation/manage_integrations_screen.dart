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
import '../../../shared/widgets/settings_service_tile.dart';

/// Every optional service in one place: toggle it on/off and inspect the last
/// observed data read. Disabling a service keeps its saved credentials.
class ManageIntegrationsScreen extends ConsumerStatefulWidget {
  const ManageIntegrationsScreen({super.key});

  @override
  ConsumerState<ManageIntegrationsScreen> createState() =>
      _ManageIntegrationsScreenState();
}

class _ManageIntegrationsScreenState
    extends ConsumerState<ManageIntegrationsScreen> {
  AppService? _saving;
  bool _saveFailed = false;

  Future<void> _toggle(AppService service, bool value) async {
    if (_saving != null || ModalRoute.of(context)?.isCurrent != true) return;
    setState(() {
      _saving = service;
      _saveFailed = false;
    });
    try {
      await ref
          .read(enabledServicesProvider.notifier)
          .setEnabled(service, value);
    } catch (_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        setState(() => _saveFailed = true);
      }
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final reading = ref.watch(enabledServicesProvider);

    return AppPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.settingsManageIntegrations),
          ),
          SliverSafeArea(
            top: false,
            sliver: SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: switch (reading) {
                    AsyncData(:final value) => _serviceSections(value),
                    AsyncError() => _loadFailure(),
                    _ => _loading(),
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _loading() {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(),
            const SizedBox(height: 12),
            Text(l10n.commonLoading),
          ],
        ),
      ),
    );
  }

  Widget _loadFailure() {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(CupertinoIcons.exclamationmark_triangle, size: 28),
            const SizedBox(height: 12),
            Text(l10n.commonError),
            const SizedBox(height: 8),
            CupertinoButton.filled(
              onPressed: () => ref.invalidate(enabledServicesProvider),
              child: Text(l10n.commonRetry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _serviceSections(Set<AppService> enabled) {
    final l10n = AppLocalizations.of(context);
    final saving = _saving;
    void toggle(AppService service, bool value) => _toggle(service, value);
    return Column(
      children: [
        const SizedBox(height: 16),
        if (_saveFailed)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                l10n.commonError,
                style: TextStyle(
                  color: CupertinoColors.systemRed.resolveFrom(context),
                ),
              ),
            ),
          ),
        SettingsSection(
          header: Text(l10n.settingsSectionMediaServices),
          children: [
            _ServiceRow(
              icon: CupertinoIcons.play_rectangle,
              color: CupertinoColors.systemPurple,
              service: AppService.jellyfin,
              title: 'Jellyfin',
              enabled: enabled.contains(AppService.jellyfin),
              busy: saving == AppService.jellyfin,
              onToggle: saving == null
                  ? (v) => toggle(AppService.jellyfin, v)
                  : null,
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute(builder: (_) => const JellyfinHomeScreen()),
              ),
            ),
            _ServiceRow(
              icon: CupertinoIcons.search,
              color: CupertinoColors.systemBlue,
              service: AppService.jellyseerr,
              title: 'Jellyseerr',
              enabled: enabled.contains(AppService.jellyseerr),
              busy: saving == AppService.jellyseerr,
              onToggle: saving == null
                  ? (v) => toggle(AppService.jellyseerr, v)
                  : null,
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
              busy: saving == AppService.sonarr,
              onToggle: saving == null
                  ? (v) => toggle(AppService.sonarr, v)
                  : null,
              onTap: () => Navigator.of(
                context,
              ).push(CupertinoPageRoute(builder: (_) => const SonarrScreen())),
            ),
            _ServiceRow(
              icon: CupertinoIcons.film,
              color: CupertinoColors.systemYellow,
              service: AppService.radarr,
              title: 'Radarr',
              enabled: enabled.contains(AppService.radarr),
              busy: saving == AppService.radarr,
              onToggle: saving == null
                  ? (v) => toggle(AppService.radarr, v)
                  : null,
              onTap: () => Navigator.of(
                context,
              ).push(CupertinoPageRoute(builder: (_) => const RadarrScreen())),
            ),
            _ServiceRow(
              icon: CupertinoIcons.music_note,
              color: CupertinoColors.systemGreen,
              service: AppService.lidarr,
              title: 'Lidarr',
              enabled: enabled.contains(AppService.lidarr),
              busy: saving == AppService.lidarr,
              onToggle: saving == null
                  ? (v) => toggle(AppService.lidarr, v)
                  : null,
              onTap: () => Navigator.of(
                context,
              ).push(CupertinoPageRoute(builder: (_) => const LidarrScreen())),
            ),
            _ServiceRow(
              icon: CupertinoIcons.book,
              color: CupertinoColors.systemOrange,
              service: AppService.readarr,
              title: 'Readarr',
              enabled: enabled.contains(AppService.readarr),
              busy: saving == AppService.readarr,
              onToggle: saving == null
                  ? (v) => toggle(AppService.readarr, v)
                  : null,
              onTap: () => Navigator.of(
                context,
              ).push(CupertinoPageRoute(builder: (_) => const ReadarrScreen())),
            ),
            _ServiceRow(
              icon: CupertinoIcons.captions_bubble,
              color: CupertinoColors.systemTeal,
              service: AppService.bazarr,
              title: 'Bazarr',
              enabled: enabled.contains(AppService.bazarr),
              busy: saving == AppService.bazarr,
              onToggle: saving == null
                  ? (v) => toggle(AppService.bazarr, v)
                  : null,
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute(builder: (_) => const BazarrHomeScreen()),
              ),
            ),
            _ServiceRow(
              icon: CupertinoIcons.dot_radiowaves_left_right,
              color: CupertinoColors.systemOrange,
              service: AppService.prowlarr,
              title: 'Prowlarr',
              enabled: enabled.contains(AppService.prowlarr),
              busy: saving == AppService.prowlarr,
              onToggle: saving == null
                  ? (v) => toggle(AppService.prowlarr, v)
                  : null,
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
              busy: saving == AppService.qbittorrent,
              onToggle: saving == null
                  ? (v) => toggle(AppService.qbittorrent, v)
                  : null,
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
              busy: saving == AppService.proxmox,
              onToggle: saving == null
                  ? (v) => toggle(AppService.proxmox, v)
                  : null,
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute(builder: (_) => const ProxmoxNodesScreen()),
              ),
            ),
            _ServiceRow(
              icon: CupertinoIcons.wifi,
              color: CupertinoColors.systemGreen,
              service: AppService.keenetic,
              title: 'Keenetic',
              enabled: enabled.contains(AppService.keenetic),
              busy: saving == AppService.keenetic,
              onToggle: saving == null
                  ? (v) => toggle(AppService.keenetic, v)
                  : null,
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute(builder: (_) => const KeeneticHomeScreen()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
      ],
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
    this.busy = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final bool enabled;
  final ValueChanged<bool>? onToggle;
  final VoidCallback onTap;
  final bool busy;

  /// When a real vendored logo exists for this service, that logo is shown
  /// via [BrandIcon] instead of the generic [icon]/[color] pair.
  final AppService service;

  @override
  Widget build(BuildContext context) {
    final service = this.service;
    return SettingsServiceTile(
      leading: hasBrandIcon(service)
          ? BrandIcon(service: service)
          : IconBadge(icon: icon, color: color),
      title: title,
      additionalInfo: SavedServiceHealthStatus(service: service),
      enabled: enabled,
      busy: busy,
      openKey: ValueKey('integration-open-${service.name}'),
      toggleKey: ValueKey('integration-toggle-${service.name}'),
      onOpen: onTap,
      onToggle: onToggle,
    );
  }
}
