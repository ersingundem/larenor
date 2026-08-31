import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../keenetic/data/keenetic_credentials_store.dart';
import '../../media/arr/data/arr_credentials_store.dart';
import '../../media/bazarr/data/bazarr_credentials_store.dart';
import '../../media/jellyfin/data/jellyfin_credentials_store.dart';
import '../../media/jellyseerr/data/jellyseerr_credentials_store.dart';
import '../../media/prowlarr/data/prowlarr_credentials_store.dart';
import '../../media/qbittorrent/data/qbittorrent_credentials_store.dart';
import '../../proxmox/data/proxmox_credentials_store.dart';
import '../data/app_service.dart';
import '../data/enabled_services_store.dart';

part 'enabled_services_providers.g.dart';

const _migratedKey = 'enabled_services_migrated';

@riverpod
EnabledServicesStore enabledServicesStore(Ref ref) => EnabledServicesStore();

/// Which optional services are toggled on. The first time this runs after
/// the toggle feature shipped, it seeds itself from whichever services
/// already have saved credentials, so existing users don't lose access to
/// something they were already using.
@riverpod
class EnabledServices extends _$EnabledServices {
  @override
  Future<Set<AppService>> build() async {
    final store = ref.watch(enabledServicesStoreProvider);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migratedKey) ?? false) {
      return store.read();
    }

    final seeded = await _seedFromExistingCredentials();
    await store.save(seeded);
    await prefs.setBool(_migratedKey, true);
    return seeded;
  }

  Future<void> setEnabled(AppService service, bool enabled) async {
    final current = state.value ?? {};
    final updated = {...current};
    if (enabled) {
      updated.add(service);
    } else {
      updated.remove(service);
    }
    state = AsyncData(updated);
    await ref.read(enabledServicesStoreProvider).save(updated);
  }

  Future<Set<AppService>> _seedFromExistingCredentials() async {
    final seeded = <AppService>{};
    if (await JellyfinCredentialsStore().read() != null) {
      seeded.add(AppService.jellyfin);
    }
    if (await JellyseerrCredentialsStore().read() != null) {
      seeded.add(AppService.jellyseerr);
    }
    if (await ArrCredentialsStore(servicePrefix: 'sonarr').read() != null) {
      seeded.add(AppService.sonarr);
    }
    if (await ArrCredentialsStore(servicePrefix: 'radarr').read() != null) {
      seeded.add(AppService.radarr);
    }
    if (await ArrCredentialsStore(servicePrefix: 'lidarr').read() != null) {
      seeded.add(AppService.lidarr);
    }
    if (await ArrCredentialsStore(servicePrefix: 'readarr').read() != null) {
      seeded.add(AppService.readarr);
    }
    if (await BazarrCredentialsStore().read() != null) {
      seeded.add(AppService.bazarr);
    }
    if (await ProwlarrCredentialsStore().read() != null) {
      seeded.add(AppService.prowlarr);
    }
    if (await QbittorrentCredentialsStore().read() != null) {
      seeded.add(AppService.qbittorrent);
    }
    if (await ProxmoxCredentialsStore().read() != null) {
      seeded.add(AppService.proxmox);
    }
    if (await KeeneticCredentialsStore().read() != null) {
      seeded.add(AppService.keenetic);
    }
    return seeded;
  }
}
