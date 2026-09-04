import 'package:larenor/core/configuration_writes.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'qbittorrent_config.dart';

/// qBittorrent's WebUI API is cookie-session based (no long-lived token),
/// so the username/password are kept (Keystore/Keychain-backed) to
/// re-authenticate on every app launch rather than a single stored token.
class QbittorrentCredentialsStore {
  QbittorrentCredentialsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _baseUrlKey = 'qbittorrent_base_url';
  static const _usernameKey = 'qbittorrent_username';
  static const _passwordKey = 'qbittorrent_password';

  final FlutterSecureStorage _storage;

  Future<QbittorrentConfig?> read() async {
    final baseUrl = await _storage.read(key: _baseUrlKey);
    final username = await _storage.read(key: _usernameKey);
    final password = await _storage.read(key: _passwordKey);
    if (baseUrl == null || username == null || password == null) return null;
    return QbittorrentConfig(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
  }

  Future<void> save({
    required String baseUrl,
    required String username,
    required String password,
  }) => ConfigurationWrites.run(() async {
    await _storage.write(key: _baseUrlKey, value: baseUrl);
    await _storage.write(key: _usernameKey, value: username);
    await _storage.write(key: _passwordKey, value: password);
  });

  Future<void> clear() => ConfigurationWrites.run(() async {
    await _storage.delete(key: _baseUrlKey);
    await _storage.delete(key: _usernameKey);
    await _storage.delete(key: _passwordKey);
  });
}
