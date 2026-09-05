import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/direct_home_access.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ha_connection_config.dart';

/// Persists the Home Assistant server URL + long-lived access token in the
/// platform Keystore/Keychain via [FlutterSecureStorage].
class CredentialsStore {
  CredentialsStore({FlutterSecureStorage? storage, DirectHomeAccess? access})
    : _access = access,
      _storage = storage ?? const FlutterSecureStorage();

  static const _baseUrlKey = 'ha_base_url';
  static const _tokenKey = 'ha_token';

  final FlutterSecureStorage _storage;
  final DirectHomeAccess? _access;
  void _check() => _access?.check();
  Future<T> _call<T>(Future<T> Function() operation, {bool mutation = false}) =>
      _access?.storage(operation, mutation: mutation) ?? operation();

  Future<HaConnectionConfig?> read() => ConfigurationWrites.run(() async {
    _check();
    final baseUrl = await _call(() => _storage.read(key: _baseUrlKey));
    final token = await _call(() => _storage.read(key: _tokenKey));
    _check();
    if (baseUrl == null || token == null) return null;
    return HaConnectionConfig(baseUrl: baseUrl, token: token);
  });

  Future<void> save(HaConnectionConfig config) =>
      ConfigurationWrites.run(() async {
        _check();
        await _call(
          () => _storage.write(key: _baseUrlKey, value: config.baseUrl),
          mutation: true,
        );
        await _call(
          () => _storage.write(key: _tokenKey, value: config.token),
          mutation: true,
        );
        _check();
      });

  Future<void> clear() => ConfigurationWrites.run(() async {
    _check();
    await _call(() => _storage.delete(key: _baseUrlKey), mutation: true);
    await _call(() => _storage.delete(key: _tokenKey), mutation: true);
    _check();
  });
}
