import '../../auth/data/ha_connection_config.dart';
import '../../keenetic/data/keenetic_config.dart';
import '../../media/arr/data/arr_config.dart';
import '../../media/bazarr/data/bazarr_config.dart';
import '../../media/jellyfin/data/jellyfin_config.dart';
import '../../media/jellyseerr/data/jellyseerr_config.dart';
import '../../media/prowlarr/data/prowlarr_config.dart';
import '../../media/qbittorrent/data/qbittorrent_config.dart';
import '../../proxmox/data/proxmox_config.dart';

/// Compare in-memory configuration fields without serializing, hashing,
/// emitting or logging credentials. These existing classes have no value ==.
bool sameHealthConfiguration(Object? previous, Object? next) {
  if (identical(previous, next)) return true;
  return switch ((previous, next)) {
    (HaConnectionConfig a, HaConnectionConfig b) =>
      a.baseUrl == b.baseUrl && a.token == b.token,
    (ArrConfig a, ArrConfig b) =>
      a.baseUrl == b.baseUrl && a.apiKey == b.apiKey,
    (BazarrConfig a, BazarrConfig b) =>
      a.baseUrl == b.baseUrl && a.apiKey == b.apiKey,
    (ProwlarrConfig a, ProwlarrConfig b) =>
      a.baseUrl == b.baseUrl && a.apiKey == b.apiKey,
    (JellyseerrConfig a, JellyseerrConfig b) =>
      a.baseUrl == b.baseUrl && a.apiKey == b.apiKey,
    (JellyfinConfig a, JellyfinConfig b) =>
      a.baseUrl == b.baseUrl &&
          a.userId == b.userId &&
          a.accessToken == b.accessToken &&
          a.deviceId == b.deviceId,
    (QbittorrentConfig a, QbittorrentConfig b) =>
      a.baseUrl == b.baseUrl &&
          a.username == b.username &&
          a.password == b.password,
    (KeeneticConfig a, KeeneticConfig b) =>
      a.baseUrl == b.baseUrl &&
          a.username == b.username &&
          a.password == b.password,
    (ProxmoxConfig a, ProxmoxConfig b) =>
      a.host == b.host &&
          a.port == b.port &&
          a.username == b.username &&
          a.realm == b.realm &&
          a.password == b.password &&
          a.allowSelfSigned == b.allowSelfSigned,
    _ => false,
  };
}
