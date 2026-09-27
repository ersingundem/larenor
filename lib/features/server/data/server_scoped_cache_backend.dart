import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/configuration_writes.dart';

String serverScopedCacheKey(
  String namespace, {
  required String coreId,
  required String homeId,
  required String accountId,
}) {
  final digest = sha256.convert(
    utf8.encode('$coreId\u0000$homeId\u0000$accountId'),
  );
  return '${namespace}_${digest.toString().substring(0, 32)}';
}

abstract interface class ServerScopedStringCacheBackend {
  Future<String?> readScoped(String key);
  Future<void> writeScoped(String key, String value, String failureCode);
  Future<bool> compareAndWriteScoped(
    String key,
    String? expected,
    String value, {
    required bool Function() current,
    required String writeFailureCode,
    required String clearFailureCode,
  });
  Future<bool> compareAndClearScoped(
    String key,
    String expected,
    String failureCode,
  );
  Future<void> clearScoped(String key, String failureCode);
}

final class SharedPreferencesScopedStringCache
    implements ServerScopedStringCacheBackend {
  const SharedPreferencesScopedStringCache(this.loadPreferences);

  final Future<SharedPreferences> Function() loadPreferences;

  @override
  Future<String?> readScoped(String key) => ConfigurationWrites.run(() async {
    final preferences = await loadPreferences();
    await preferences.reload();
    return preferences.getString(key);
  });

  @override
  Future<void> writeScoped(String key, String value, String failureCode) =>
      ConfigurationWrites.run(() async {
        final preferences = await loadPreferences();
        if (!await preferences.setString(key, value)) {
          throw StateError(failureCode);
        }
      });

  @override
  Future<bool> compareAndWriteScoped(
    String key,
    String? expected,
    String value, {
    required bool Function() current,
    required String writeFailureCode,
    required String clearFailureCode,
  }) => ConfigurationWrites.run(() async {
    bool isCurrent() {
      try {
        return current();
      } catch (_) {
        return false;
      }
    }

    if (!isCurrent()) return false;
    final preferences = await loadPreferences();
    if (!isCurrent()) return false;
    await preferences.reload();
    if (!isCurrent() || preferences.getString(key) != expected) return false;
    if (!await preferences.setString(key, value)) {
      throw StateError(writeFailureCode);
    }
    if (!isCurrent()) {
      await preferences.reload();
      if (preferences.getString(key) == value &&
          !await preferences.remove(key)) {
        throw StateError(clearFailureCode);
      }
      return false;
    }
    return true;
  });

  @override
  Future<bool> compareAndClearScoped(
    String key,
    String expected,
    String failureCode,
  ) => ConfigurationWrites.run(() async {
    final preferences = await loadPreferences();
    await preferences.reload();
    if (preferences.getString(key) != expected) return false;
    if (!await preferences.remove(key)) throw StateError(failureCode);
    return true;
  });

  @override
  Future<void> clearScoped(String key, String failureCode) =>
      ConfigurationWrites.run(() async {
        final preferences = await loadPreferences();
        if (!await preferences.remove(key)) throw StateError(failureCode);
      });
}
