import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/configuration_writes.dart';
import '../../../core/direct_home_access.dart';

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

@riverpod
EnabledServicesStore enabledServicesStore(Ref ref) =>
    EnabledServicesStore(access: ref.watch(directHomeAccessProvider));

/// Which optional services are toggled on. The first time this runs after
/// the toggle feature shipped, it seeds itself from whichever services
/// already have saved credentials, so existing users don't lose access to
/// something they were already using.
@riverpod
class EnabledServices extends _$EnabledServices {
  @override
  Future<Set<AppService>> build() {
    final access = ref.watch(directHomeAccessProvider);
    final store = ref.watch(enabledServicesStoreProvider);
    return ConfigurationWrites.run(() async {
      access.check();
      if (await store.migrationComplete()) {
        final result = await store.read();
        access.check();
        return result;
      }
      final seeded = await _seedFromExistingCredentials(access);
      access.check();
      await store.save(seeded, markMigrated: true);
      access.check();
      return seeded;
    });
  }

  Future<void> setEnabled(AppService service, bool enabled) {
    if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
    final access = ref.read(directHomeAccessProvider);
    final store = ref.read(enabledServicesStoreProvider);
    return ConfigurationWrites.run(() async {
      access.check();
      final updated = {...await store.read()};
      access.check();
      if (enabled) {
        updated.add(service);
      } else {
        updated.remove(service);
      }
      await store.save(updated);
      access.check();
      if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
      state = AsyncData(updated);
    });
  }

  Future<Set<AppService>> _seedFromExistingCredentials(
    DirectHomeAccess access,
  ) async {
    access.check();
    final storage = _SeedStorage(access);
    final seeded = <AppService>{};
    if (await JellyfinCredentialsStore(storage: storage).read() != null) {
      seeded.add(AppService.jellyfin);
    }
    if (await JellyseerrCredentialsStore(storage: storage).read() != null) {
      seeded.add(AppService.jellyseerr);
    }
    if (await ArrCredentialsStore(
          servicePrefix: 'sonarr',
          storage: storage,
        ).read() !=
        null) {
      seeded.add(AppService.sonarr);
    }
    if (await ArrCredentialsStore(
          servicePrefix: 'radarr',
          storage: storage,
        ).read() !=
        null) {
      seeded.add(AppService.radarr);
    }
    if (await ArrCredentialsStore(
          servicePrefix: 'lidarr',
          storage: storage,
        ).read() !=
        null) {
      seeded.add(AppService.lidarr);
    }
    if (await ArrCredentialsStore(
          servicePrefix: 'readarr',
          storage: storage,
        ).read() !=
        null) {
      seeded.add(AppService.readarr);
    }
    if (await BazarrCredentialsStore(storage: storage).read() != null) {
      seeded.add(AppService.bazarr);
    }
    if (await ProwlarrCredentialsStore(storage: storage).read() != null) {
      seeded.add(AppService.prowlarr);
    }
    if (await QbittorrentCredentialsStore(storage: storage).read() != null) {
      seeded.add(AppService.qbittorrent);
    }
    if (await ProxmoxCredentialsStore(storage: storage).read() != null) {
      seeded.add(AppService.proxmox);
    }
    if (await KeeneticCredentialsStore(storage: storage).read() != null) {
      seeded.add(AppService.keenetic);
    }
    return seeded;
  }
}

/// Credential seeding can also create Jellyfin's per-install device ID. Each
/// underlying keyed read/write stays source-bound without changing the other
/// services' public store/provider contracts in this first packet.
class _SeedStorage extends FlutterSecureStorage {
  const _SeedStorage(this.access);
  final DirectHomeAccess access;
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => access.storage(
    () => super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    ),
  );
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => access.storage(
    () => super.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    ),
    mutation: true,
  );
}
