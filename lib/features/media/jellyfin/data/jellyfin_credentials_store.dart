import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'jellyfin_config.dart';

class JellyfinCredentialsStore {
  JellyfinCredentialsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _baseUrlKey = 'jellyfin_base_url';
  static const _userIdKey = 'jellyfin_user_id';
  static const _tokenKey = 'jellyfin_access_token';
  static const _deviceIdKey = 'jellyfin_device_id';

  final FlutterSecureStorage _storage;

  Future<JellyfinConfig?> read() async {
    final baseUrl = await _storage.read(key: _baseUrlKey);
    final userId = await _storage.read(key: _userIdKey);
    final token = await _storage.read(key: _tokenKey);
    if (baseUrl == null || userId == null || token == null) return null;
    return JellyfinConfig(
      baseUrl: baseUrl,
      userId: userId,
      accessToken: token,
      deviceId: await deviceId(),
    );
  }

  /// Always returns a stable per-install id, generating and persisting one
  /// on first use — independent of whether the user is currently signed in,
  /// since it's needed to authenticate the very first login request too.
  Future<String> deviceId() => _ensureDeviceId();

  Future<void> save({
    required String baseUrl,
    required String userId,
    required String accessToken,
  }) async {
    await _storage.write(key: _baseUrlKey, value: baseUrl);
    await _storage.write(key: _userIdKey, value: userId);
    await _storage.write(key: _tokenKey, value: accessToken);
  }

  Future<void> clear() async {
    await _storage.delete(key: _baseUrlKey);
    await _storage.delete(key: _userIdKey);
    await _storage.delete(key: _tokenKey);
  }

  /// A stable per-install identifier Jellyfin uses to recognize "this
  /// device" across sessions (shows up in the server's device list).
  Future<String> _ensureDeviceId() async {
    final existing = await _storage.read(key: _deviceIdKey);
    if (existing != null) return existing;
    final generated = 'larenor-${DateTime.now().microsecondsSinceEpoch}';
    await _storage.write(key: _deviceIdKey, value: generated);
    return generated;
  }
}
