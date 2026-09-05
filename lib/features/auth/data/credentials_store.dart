import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/direct_home_access.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ha_connection_config.dart';

/// Persists the Home Assistant server URL + long-lived access token in the
/// platform Keystore/Keychain via [FlutterSecureStorage].
class CredentialsStore {
  CredentialsStore({FlutterSecureStorage? storage, DirectHomeAccess? access})
    // Keep the public parameter name while the ownership field stays private.
    // ignore: prefer_initializing_formals
    : _access = access,
      _storage = storage ?? const FlutterSecureStorage();

  static const _baseUrlKey = 'ha_base_url';
  static const _tokenKey = 'ha_token';

  /// Private durable uncertainty marker; never exported as connection data.
  /// Only a complete explicit save/clear can remove it. It contains no secrets.
  static const pendingMutationKey = 'ha_connection_pending_v1';

  final FlutterSecureStorage _storage;
  final DirectHomeAccess? _access;
  void _check() => _access?.check();
  Future<T> _call<T>(
    Future<T> Function() operation, {
    bool mutation = false,
  }) async {
    if (_access != null) return _access.storage(operation, mutation: mutation);
    // Standalone stores retain legacy Direct compatibility, not raw platform
    // errors (which can include credential values).
    try {
      return await operation();
    } catch (_) {
      throw DirectHomeAccessException(
        mutation ? 'write_unconfirmed' : 'storage_failed',
      );
    }
  }

  Future<void> _beginMutation() => _call(
    () => _storage.write(key: pendingMutationKey, value: '1'),
    mutation: true,
  );

  Future<void> _completeMutation() =>
      _call(() => _storage.delete(key: pendingMutationKey), mutation: true);

  Future<HaConnectionConfig?> read() => ConfigurationWrites.run(() async {
    _check();
    final pending = await _call(() => _storage.read(key: pendingMutationKey));
    if (pending != null) {
      throw const DirectHomeAccessException('pending_mutation');
    }
    final baseUrl = await _call(() => _storage.read(key: _baseUrlKey));
    final token = await _call(() => _storage.read(key: _tokenKey));
    _check();
    if (baseUrl == null || token == null) return null;
    return HaConnectionConfig(baseUrl: baseUrl, token: token);
  });

  Future<void> save(HaConnectionConfig config) =>
      ConfigurationWrites.run(() async {
        _check();
        await _beginMutation();
        await _call(
          () => _storage.write(key: _baseUrlKey, value: config.baseUrl),
          mutation: true,
        );
        await _call(
          () => _storage.write(key: _tokenKey, value: config.token),
          mutation: true,
        );
        _check();
        await _completeMutation();
      });

  Future<void> clear() => ConfigurationWrites.run(() async {
    _check();
    await _beginMutation();
    await _call(() => _storage.delete(key: _baseUrlKey), mutation: true);
    await _call(() => _storage.delete(key: _tokenKey), mutation: true);
    _check();
    await _completeMutation();
  });
}
