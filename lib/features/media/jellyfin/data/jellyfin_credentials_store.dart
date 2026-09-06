import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../../core/configuration_writes.dart';
import '../../../../core/direct_credential_record.dart';
import '../../../../core/direct_home_access.dart';
import 'jellyfin_config.dart';

class JellyfinCredentialsStore {
  JellyfinCredentialsStore({FlutterSecureStorage? storage, DirectHomeAccess? access})
    : _storage = storage ?? const FlutterSecureStorage(),
      _access = access,
      _record = DirectCredentialRecord(service: DirectCredentialService.jellyfin,
        storage: storage, access: access);

  static const _deviceIdKey = 'jellyfin_device_id';
  final FlutterSecureStorage _storage;
  final DirectHomeAccess? _access;
  final DirectCredentialRecord _record;

  void _check([bool Function()? isCurrent]) {
    _access?.check();
    if (isCurrent == null) return;
    try { if (isCurrent()) return; } catch (_) { /* Static denial only. */ }
    throw const DirectHomeAccessException('unavailable');
  }

  Future<JellyfinConfig?> read() async {
    final fields = await _record.readFields();
    _check();
    final baseUrl = fields['baseUrl'], userId = fields['userId'], token = fields['accessToken'];
    if (baseUrl == null || userId == null || token == null) return null;
    final device = await deviceId();
    _check();
    return JellyfinConfig(baseUrl: baseUrl, userId: userId, accessToken: token, deviceId: device);
  }

  Future<void> save({required String baseUrl, required String userId,
    required String accessToken, bool Function()? isCurrent}) => _record.replaceAll(
      {'baseUrl': baseUrl, 'userId': userId, 'accessToken': accessToken}, isCurrent: isCurrent);

  Future<void> clear({bool Function()? isCurrent}) => _record.clear(isCurrent: isCurrent);

  Future<T> _deviceCall<T>(Future<T> Function() operation, {
    bool mutation = false, bool Function()? isCurrent,
  }) async {
    _check(isCurrent);
    try {
      final result = _access == null ? await operation() : await _access.storage(() {
        _check(isCurrent);
        return operation();
      }, mutation: mutation);
      _check(isCurrent);
      return result;
    } catch (error) {
      if (mutation) throw const DirectHomeAccessException('write_unconfirmed');
      if (error is DirectHomeAccessException) rethrow;
      throw const DirectHomeAccessException('storage_failed');
    }
  }

  /// Per-install identity, separate from the credential tuple and never cleared
  /// by sign-out. Only the current Direct owner can read or create it.
  Future<String> deviceId({bool Function()? isCurrent}) => ConfigurationWrites.run(() async {
    _check(isCurrent);
    final existing = await _deviceCall(() => _storage.read(key: _deviceIdKey), isCurrent: isCurrent);
    _check(isCurrent);
    if (existing != null) return existing;
    final generated = 'larenor-${DateTime.now().microsecondsSinceEpoch}';
    await _deviceCall(() => _storage.write(key: _deviceIdKey, value: generated),
      mutation: true, isCurrent: isCurrent);
    _check(isCurrent);
    return generated;
  });
}
