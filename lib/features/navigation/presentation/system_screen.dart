import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/brand_icon.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../../../shared/widgets/integration_health_status.dart';
import '../../../shared/widgets/operational_service_scope.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../keenetic/presentation/keenetic_home_screen.dart';
import '../../auth/providers/auth_providers.dart';
import '../../health/data/integration_health.dart';
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
import '../../settings/data/app_service.dart';
import '../../settings/providers/enabled_services_providers.dart';
import '../../wellbeing/data/wellbeing_disclosure_policy.dart';
import '../providers/service_connection_providers.dart';
import '../search/domain/local_search_index.dart';
import 'app_shell_actions.dart';

class SystemScreen extends ConsumerWidget {
  const SystemScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final enabled = ref.watch(enabledServicesProvider);
    final privacy = ref.watch(wellbeingDisclosureProvider);
    final connections = {
      for (final service in AppService.values)
        service: ref.watch(savedServiceConnectionProvider(service)),
    };
    final services =
        AppService.values
            .where(
              (service) =>
                  (enabled.value?.contains(service) ?? false) ||
                  connections[service]!.value == true ||
                  connections[service]!.hasError,
            )
            .toList()
          ..sort(
            (a, b) => serviceDisplayName(a).compareTo(serviceDisplayName(b)),
          );
    final loading =
        enabled.isLoading ||
        connections.values.any((connection) => connection.isLoading);

    return AppPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.navigationSystem),
            trailing: const AppShellActions(),
          ),
          const SliverToBoxAdapter(child: _HomeAssistantHealthCard()),
          SliverToBoxAdapter(
            child: SettingsSection(
              children: [
                CupertinoListTile(
                  leading: const IconBadge(
                    icon: CupertinoIcons.heart,
                    color: CupertinoColors.systemPink,
                  ),
                  title: Text(l10n.wellbeingTitle),
                  trailing: const CupertinoListTileChevron(),
                  onTap: () => context.push('/wellbeing'),
                ),
                if (!privacy.isLoading &&
                    !privacy.hasError &&
                    privacy.value?.reviewRequired == true)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l10n.backupPrivacyReviewRequired),
                  ),
              ],
            ),
          ),
          if (enabled.hasError)
            SliverToBoxAdapter(
              child: _ConnectionMessage(
                message: l10n.commonError,
                onRetry: () => ref.invalidate(enabledServicesProvider),
              ),
            ),
          if (services.isNotEmpty)
            SliverToBoxAdapter(
              child: SettingsSection(
                header: Text(l10n.settingsCategoryIntegrations),
                children: [
                  for (final service in services)
                    CupertinoListTile(
                      key: ValueKey('system-${service.name}'),
                      leading: hasBrandIcon(service)
                          ? BrandIcon(service: service)
                          : const IconBadge(
                              icon: CupertinoIcons.wifi,
                              color: CupertinoColors.systemGreen,
                            ),
                      title: Text(serviceDisplayName(service)),
                      subtitle: SavedServiceHealthStatus(service: service),
                      trailing: const CupertinoListTileChevron(),
                      onTap: () => context.push('/system/${service.name}'),
                    ),
                ],
              ),
            )
          else if (loading)
            const SliverFilledMessage(child: CupertinoActivityIndicator())
          else
            SliverFilledMessage(
              child: _ConnectionMessage(
                message: l10n.navigationNoServices,
                showConfigure: true,
              ),
            ),
          if (services.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: CupertinoButton(
                  onPressed: () => context.push('/settings'),
                  child: Text(l10n.navigationConfigure),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HomeAssistantHealthCard extends ConsumerWidget {
  const _HomeAssistantHealthCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionConfigProvider);
    final l10n = AppLocalizations.of(context);
    return SettingsSection(
      children: [
        CupertinoListTile(
          key: const ValueKey('system-home-assistant'),
          leading: const IconBadge(
            icon: CupertinoIcons.house_fill,
            color: CupertinoColors.systemBlue,
          ),
          title: const Text('Home Assistant'),
          subtitle: connection.isLoading
              ? Text(l10n.commonLoading)
              : connection.hasError
              ? Text(l10n.commonError)
              : IntegrationHealthStatus(
                  id: IntegrationId.ha,
                  configured: connection.value != null,
                  compact: true,
                ),
        ),
      ],
    );
  }
}

/// This guard is above every operational widget: a missing, loading or failed
/// saved connection must never fall through to a service's inline setup form.
class OperationalServiceScreen extends ConsumerWidget {
  const OperationalServiceScreen({super.key, required this.service});

  final AppService service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(savedServiceConnectionProvider(service));
    final l10n = AppLocalizations.of(context);
    if (!connection.isLoading &&
        !connection.hasError &&
        connection.value == true) {
      return OperationalServiceScope(
        status: ServiceHealthBanner(service: service),
        child: switch (service) {
          AppService.jellyfin => const JellyfinHomeScreen(),
          AppService.jellyseerr => const JellyseerrHomeScreen(),
          AppService.sonarr => const SonarrScreen(),
          AppService.radarr => const RadarrScreen(),
          AppService.lidarr => const LidarrScreen(),
          AppService.readarr => const ReadarrScreen(),
          AppService.bazarr => const BazarrHomeScreen(),
          AppService.prowlarr => const ProwlarrIndexersScreen(),
          AppService.qbittorrent => const QbittorrentTorrentsScreen(),
          AppService.proxmox => const ProxmoxNodesScreen(),
          AppService.keenetic => const KeeneticHomeScreen(),
        },
      );
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(serviceDisplayName(service)),
      ),
      child: SafeArea(
        child: Center(
          child: connection.isLoading
              ? const CupertinoActivityIndicator()
              : _ConnectionMessage(
                  message: connection.hasError
                      ? l10n.commonError
                      : l10n.navigationUnconfigured,
                  showConfigure: true,
                  onRetry: connection.hasError
                      ? () => reloadSavedServiceConnection(ref, service)
                      : null,
                ),
        ),
      ),
    );
  }
}

class _ConnectionMessage extends StatelessWidget {
  const _ConnectionMessage({
    required this.message,
    this.onRetry,
    this.showConfigure = false,
  });

  final String message;
  final VoidCallback? onRetry;
  final bool showConfigure;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null)
            CupertinoButton(onPressed: onRetry, child: Text(l10n.commonRetry)),
          if (showConfigure)
            CupertinoButton(
              key: const ValueKey('system-configure'),
              onPressed: () => context.push('/settings'),
              child: Text(l10n.navigationConfigure),
            ),
        ],
      ),
    );
  }
}
