import 'package:larenor/core/configuration_writes.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ha_connection_config.dart';

/// Persists the Home Assistant server URL + long-lived access token in the
/// platform Keystore/Keychain via [FlutterSecureStorage].
class CredentialsStore {
  CredentialsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _baseUrlKey = 'ha_base_url';
  static const _tokenKey = 'ha_token';

  final FlutterSecureStorage _storage;

  Future<HaConnectionConfig?> read() async {
    final baseUrl = await _storage.read(key: _baseUrlKey);
    final token = await _storage.read(key: _tokenKey);
    if (baseUrl == null || token == null) return null;
    return HaConnectionConfig(baseUrl: baseUrl, token: token);
  }

  Future<void> save(HaConnectionConfig config) =>
      ConfigurationWrites.run(() async {
        await _storage.write(key: _baseUrlKey, value: config.baseUrl);
        await _storage.write(key: _tokenKey, value: config.token);
      });

  Future<void> clear() => ConfigurationWrites.run(() async {
    await _storage.delete(key: _baseUrlKey);
    await _storage.delete(key: _tokenKey);
  });
}
