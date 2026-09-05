import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'configuration_writes.dart';
import 'direct_home_access.dart';

/// Closed local record identities. These markers are private recovery state,
/// never credential fields, exported configuration or permission to use Core.
enum DirectCredentialService {
  jellyfin, jellyseerr, sonarr, radarr, lidarr, readarr, bazarr, prowlarr,
  qbittorrent, keenetic, proxmox;

  String get pendingMutationKey => '${name}_connection_pending_v1';

  Map<String, String> get _fields => switch (this) {
    jellyfin => const {
      'baseUrl': 'jellyfin_base_url', 'userId': 'jellyfin_user_id',
      'accessToken': 'jellyfin_access_token',
    },
    jellyseerr => const {'baseUrl': 'jellyseerr_base_url', 'apiKey': 'jellyseerr_api_key'},
    sonarr => const {'baseUrl': 'sonarr_base_url', 'apiKey': 'sonarr_api_key'},
    radarr => const {'baseUrl': 'radarr_base_url', 'apiKey': 'radarr_api_key'},
    lidarr => const {'baseUrl': 'lidarr_base_url', 'apiKey': 'lidarr_api_key'},
    readarr => const {'baseUrl': 'readarr_base_url', 'apiKey': 'readarr_api_key'},
    bazarr => const {'baseUrl': 'bazarr_base_url', 'apiKey': 'bazarr_api_key'},
    prowlarr => const {'baseUrl': 'prowlarr_base_url', 'apiKey': 'prowlarr_api_key'},
    qbittorrent => const {
      'baseUrl': 'qbittorrent_base_url', 'username': 'qbittorrent_username',
      'password': 'qbittorrent_password',
    },
    keenetic => const {
      'baseUrl': 'keenetic_base_url', 'username': 'keenetic_username',
      'password': 'keenetic_password',
    },
    proxmox => const {
      'host': 'proxmox_host', 'port': 'proxmox_port',
      'username': 'proxmox_username', 'realm': 'proxmox_realm',
      'password': 'proxmox_password', 'allowSelfSigned': 'proxmox_allow_self_signed',
    },
  };
}

/// Serial multi-field storage with uncertainty recorded before the first field
/// effect. A failed response never triggers rollback, cleanup or automatic retry.
/// Typed stores retain validation of their own configuration shape.
final class DirectCredentialRecord {
  DirectCredentialRecord({
    required this.service,
    FlutterSecureStorage? storage,
    DirectHomeAccess? access,
  }) : _storage = storage ?? const FlutterSecureStorage(), _access = access;

  final DirectCredentialService service;
  final FlutterSecureStorage _storage;
  final DirectHomeAccess? _access;
  void _check() => _access?.check();

  Future<T> _call<T>(Future<T> Function() operation, {bool mutation = false}) async {
    _check();
    if (_access != null) return _access.storage(operation, mutation: mutation);
    try {
      return await operation();
    } catch (_) {
      throw DirectHomeAccessException(mutation ? 'write_unconfirmed' : 'storage_failed');
    }
  }

  Future<Map<String, String?>> readFields() => ConfigurationWrites.run(() async {
    _check();
    final pending = await _call(() => _storage.read(key: service.pendingMutationKey));
    _check();
    if (pending != null) throw const DirectHomeAccessException('pending_mutation');
    final result = <String, String?>{};
    for (final field in service._fields.entries) {
      result[field.key] = await _call(() => _storage.read(key: field.value));
      _check();
    }
    return Map.unmodifiable(result);
  });

  Future<void> replaceAll(Map<String, String> fields) {
    // Freeze before waiting for the queue; never retain the caller's map.
    if (fields.length != service._fields.length ||
        !service._fields.keys.every(fields.containsKey)) {
      throw ArgumentError('invalid_fields');
    }
    final values = Map<String, String>.unmodifiable(fields);
    return _mutate(values);
  }

  Future<void> clear() => _mutate(null);

  Future<void> _mutate(Map<String, String>? values) => ConfigurationWrites.run(() async {
    _check();
    await _call(() => _storage.write(key: service.pendingMutationKey, value: '1'), mutation: true);
    for (final field in service._fields.entries) {
      _check();
      if (values == null) {
        await _call(() => _storage.delete(key: field.value), mutation: true);
      } else {
        await _call(() => _storage.write(key: field.value, value: values[field.key]!), mutation: true);
      }
    }
    _check();
    await _call(() => _storage.delete(key: service.pendingMutationKey), mutation: true);
  });

  @override
  String toString() => 'DirectCredentialRecord';
}
