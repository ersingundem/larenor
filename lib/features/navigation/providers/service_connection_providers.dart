import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../keenetic/providers/keenetic_providers.dart';
import '../../health/data/integration_health.dart';
import '../../health/providers/health_providers.dart';
import '../../media/arr/providers/lidarr_providers.dart';
import '../../media/arr/providers/radarr_providers.dart';
import '../../media/arr/providers/readarr_providers.dart';
import '../../media/arr/providers/sonarr_providers.dart';
import '../../media/bazarr/providers/bazarr_providers.dart';
import '../../media/jellyfin/providers/jellyfin_providers.dart';
import '../../media/jellyseerr/providers/jellyseerr_providers.dart';
import '../../media/prowlarr/providers/prowlarr_providers.dart';
import '../../media/qbittorrent/providers/qbittorrent_providers.dart';
import '../../proxmox/providers/proxmox_providers.dart';
import '../../settings/data/app_service.dart';

/// Reads local configuration only. A saved connection is not evidence that a
/// service is online; clients and remote content are created on opening it.
final savedServiceConnectionProvider = Provider.autoDispose
    .family<AsyncValue<bool>, AppService>((ref, service) {
      final AsyncValue<Object?> connection = switch (service) {
        AppService.jellyfin => ref.watch(jellyfinConnectionProvider),
        AppService.jellyseerr => ref.watch(jellyseerrConnectionProvider),
        AppService.sonarr => ref.watch(sonarrConnectionProvider),
        AppService.radarr => ref.watch(radarrConnectionProvider),
        AppService.lidarr => ref.watch(lidarrConnectionProvider),
        AppService.readarr => ref.watch(readarrConnectionProvider),
        AppService.bazarr => ref.watch(bazarrConnectionProvider),
        AppService.prowlarr => ref.watch(prowlarrConnectionProvider),
        AppService.qbittorrent => ref.watch(qbittorrentConnectionProvider),
        AppService.proxmox => ref.watch(proxmoxConnectionProvider),
        AppService.keenetic => ref.watch(keeneticConnectionProvider),
      };
      if (!connection.isLoading && !connection.hasError) {
        ref
            .watch(healthMonitorProvider)
            .synchronizeConfiguration(
              IntegrationId.values.byName(service.name),
              connection.value,
            );
      }
      return connection.whenData((value) => value != null);
    });

/// Retry the underlying storage read, not just the derived status value.
void reloadSavedServiceConnection(WidgetRef ref, AppService service) {
  switch (service) {
    case AppService.jellyfin:
      ref.invalidate(jellyfinConnectionProvider);
    case AppService.jellyseerr:
      ref.invalidate(jellyseerrConnectionProvider);
    case AppService.sonarr:
      ref.invalidate(sonarrConnectionProvider);
    case AppService.radarr:
      ref.invalidate(radarrConnectionProvider);
    case AppService.lidarr:
      ref.invalidate(lidarrConnectionProvider);
    case AppService.readarr:
      ref.invalidate(readarrConnectionProvider);
    case AppService.bazarr:
      ref.invalidate(bazarrConnectionProvider);
    case AppService.prowlarr:
      ref.invalidate(prowlarrConnectionProvider);
    case AppService.qbittorrent:
      ref.invalidate(qbittorrentConnectionProvider);
    case AppService.proxmox:
      ref.invalidate(proxmoxConnectionProvider);
    case AppService.keenetic:
      ref.invalidate(keeneticConnectionProvider);
  }
}
