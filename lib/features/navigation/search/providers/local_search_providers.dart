import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../dashboard/domain/dashboard_room.dart';
import '../../../dashboard/providers/dashboard_providers.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../../ha_client/data/models/ha_entity.dart';
import '../../../wellbeing/providers/wellbeing_providers.dart';
import '../../../wellbeing/providers/wellbeing_privacy_providers.dart';
import '../../../keenetic/providers/keenetic_providers.dart';
import '../../../media/arr/providers/lidarr_providers.dart';
import '../../../media/arr/providers/radarr_providers.dart';
import '../../../media/arr/providers/readarr_providers.dart';
import '../../../media/arr/providers/sonarr_providers.dart';
import '../../../media/bazarr/providers/bazarr_providers.dart';
import '../../../media/hub/domain/media_library_index.dart';
import '../../../media/hub/domain/media_title.dart';
import '../../../media/hub/providers/media_catalog_providers.dart';
import '../../../media/jellyfin/providers/jellyfin_providers.dart';
import '../../../media/jellyseerr/providers/jellyseerr_providers.dart';
import '../../../media/prowlarr/providers/prowlarr_providers.dart';
import '../../../media/qbittorrent/providers/qbittorrent_providers.dart';
import '../../../proxmox/providers/proxmox_providers.dart';
import '../../../settings/data/app_service.dart';
import '../../../settings/providers/enabled_services_providers.dart';
import '../domain/local_search_index.dart';
import '../domain/navigation_target.dart';

class _EntityNames {
  const _EntityNames(this.names);
  final Map<String, String> names;
  @override
  bool operator ==(Object other) =>
      other is _EntityNames && mapEquals(names, other.names);
  @override
  int get hashCode => Object.hashAllUnordered(
    names.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}

/// Search listens only to caches that already exist. In particular, opening
/// Search never initializes an HA connection, fetches a media library or logs
/// in to Proxmox/Keenetic. No provider is parameterized by the search text.
final localSearchIndexProvider =
    NotifierProvider.autoDispose<LocalSearchIndexController, LocalSearchIndex>(
      LocalSearchIndexController.new,
    );

class LocalSearchIndexController extends Notifier<LocalSearchIndex> {
  _EntityNames? _names;
  List<DashboardRoom>? _rooms;
  MediaLibraryIndex? _library;
  List<MediaRowData>? _rows;
  Set<AppService>? _services;
  LocalSearchIndex? _index;

  @override
  LocalSearchIndex build() {
    final privacy = ref.watch(wellbeingPrivateEntityIdsProvider);
    final names = ref.exists(entitiesProvider)
        ? ref.watch(
            entitiesProvider.select(
              (states) => _EntityNames({
                for (final entry
                    in _visibleCache(states)?.entries ??
                        const <MapEntry<String, HaEntity>>[])
                  if (isPublicHaEntity(privacy, entry.key))
                    entry.key: entry.value.friendlyName,
              }),
            ),
          )
        : const _EntityNames({});
    final rooms = ref.exists(dashboardLayoutProvider)
        ? ref.watch(
                dashboardLayoutProvider.select((layout) => layout.value?.rooms),
              ) ??
              const <DashboardRoom>[]
        : const <DashboardRoom>[];
    final library = ref.exists(mediaLibraryIndexProvider)
        ? _visibleCache(ref.watch(mediaLibraryIndexProvider))
        : null;
    final rows = ref.exists(mediaHubRowsProvider)
        ? _visibleCache(ref.watch(mediaHubRowsProvider))
        : null;
    final services = _availableCachedServices();
    // Refreshing the passive cache view never renormalizes a 5000-entity
    // index unless searchable metadata actually changed.
    if (_index != null &&
        names == _names &&
        listEquals(rooms, _rooms) &&
        identical(library, _library) &&
        identical(rows, _rows) &&
        setEquals(services, _services)) {
      return _index!;
    }
    _names = names;
    _rooms = rooms;
    _library = library;
    _rows = rows;
    _services = services;
    final media = <MediaTitle>[
      for (final row in rows ?? const <MediaRowData>[]) ...row.titles,
      if (library != null)
        for (final item in library.jellyfinItems)
          if (item.type == 'Movie' || item.type == 'Series')
            ?mediaTitleFromJellyfin(
              item,
              imageUrl: (id, {String type = 'Primary', String? tag}) => null,
            ),
    ];
    return _index = LocalSearchIndex.build(
      pages: HomePageTarget.values,
      mediaPages: MediaPageTarget.values,
      rooms: rooms,
      entities: [
        for (final entry in names.names.entries)
          LocalSearchEntity(entityId: entry.key, name: entry.value),
      ],
      media: media,
      services: services,
    );
  }

  /// Recheck providers that may have appeared while another tab was active.
  /// Called on entering Search and after a debounced query, not on raw keys.
  void refreshCachedSources() => ref.invalidateSelf();

  Set<AppService> _availableCachedServices() {
    final enabled = ref.exists(enabledServicesProvider)
        ? ref.watch(enabledServicesProvider).value ?? const <AppService>{}
        : const <AppService>{};
    final configured = <AppService>{};
    void add(AppService service, bool available) {
      if (available && enabled.contains(service)) configured.add(service);
    }

    add(
      AppService.jellyfin,
      ref.exists(jellyfinConnectionProvider) &&
          ref.watch(jellyfinConnectionProvider).value != null,
    );
    add(
      AppService.jellyseerr,
      ref.exists(jellyseerrConnectionProvider) &&
          ref.watch(jellyseerrConnectionProvider).value != null,
    );
    add(
      AppService.sonarr,
      ref.exists(sonarrConnectionProvider) &&
          ref.watch(sonarrConnectionProvider).value != null,
    );
    add(
      AppService.radarr,
      ref.exists(radarrConnectionProvider) &&
          ref.watch(radarrConnectionProvider).value != null,
    );
    add(
      AppService.lidarr,
      ref.exists(lidarrConnectionProvider) &&
          ref.watch(lidarrConnectionProvider).value != null,
    );
    add(
      AppService.readarr,
      ref.exists(readarrConnectionProvider) &&
          ref.watch(readarrConnectionProvider).value != null,
    );
    add(
      AppService.bazarr,
      ref.exists(bazarrConnectionProvider) &&
          ref.watch(bazarrConnectionProvider).value != null,
    );
    add(
      AppService.prowlarr,
      ref.exists(prowlarrConnectionProvider) &&
          ref.watch(prowlarrConnectionProvider).value != null,
    );
    add(
      AppService.qbittorrent,
      ref.exists(qbittorrentConnectionProvider) &&
          ref.watch(qbittorrentConnectionProvider).value != null,
    );
    add(
      AppService.proxmox,
      ref.exists(proxmoxConnectionProvider) &&
          ref.watch(proxmoxConnectionProvider).value != null,
    );
    add(
      AppService.keenetic,
      ref.exists(keeneticConnectionProvider) &&
          ref.watch(keeneticConnectionProvider).value != null,
    );
    return configured;
  }
}

final localSearchResultsProvider = Provider.autoDispose
    .family<List<LocalSearchItem>, String>((ref, query) {
      return ref.watch(localSearchIndexProvider).search(query);
    });

// Dependency reloads can represent another server/account. AsyncValue keeps
// the previous value while loading; never expose that value through Search.
// An explicit refresh of the same source may keep its useful cached results.
T? _visibleCache<T>(AsyncValue<T> value) =>
    value.isReloading ? null : value.value;
