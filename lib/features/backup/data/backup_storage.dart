import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Narrow injectable adapter. Null writes remove a key. The repository supplies
/// only its fixed allowlist; no API ever enumerates or exports all secure data.
abstract interface class BackupStorage {
  Future<Object?> readPreference(String key);
  Future<void> writePreference(String key, Object? value);
  Future<String?> readSecret(String key);
  Future<void> writeSecret(String key, String? value);
}

class PlatformBackupStorage implements BackupStorage {
  PlatformBackupStorage({FlutterSecureStorage? secureStorage})
    : _secure = secureStorage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _secure;

  @override
  Future<Object?> readPreference(String key) async {
    final preferences = await SharedPreferences.getInstance();
    // Legacy setters update their cache before the platform acknowledges them.
    // A restore target is bound to persisted data, never that optimistic cache.
    await preferences.reload();
    return preferences.get(key);
  }

  @override
  Future<void> writePreference(String key, Object? value) async {
    final prefs = await SharedPreferences.getInstance();
    final result = switch (value) {
      null => await prefs.remove(key),
      final bool v => await prefs.setBool(key, v),
      final int v => await prefs.setInt(key, v),
      final String v => await prefs.setString(key, v),
      final List<String> v => await prefs.setStringList(key, v),
      final List v => await prefs.setStringList(key, v.cast<String>()),
      _ => throw ArgumentError('Unsupported preference type.'),
    };
    if (!result) throw StateError('Preference storage rejected a write.');
  }

  @override
  Future<String?> readSecret(String key) => _secure.read(key: key);

  @override
  Future<void> writeSecret(String key, String? value) => value == null
      ? _secure.delete(key: key)
      : _secure.write(key: key, value: value);
}
