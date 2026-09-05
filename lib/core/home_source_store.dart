import 'package:shared_preferences/shared_preferences.dart';

import 'configuration_writes.dart';

/// A local preference only; selecting Core does not establish its authority.
enum HomeSource { directLocal, verifiedCore }

abstract interface class HomeSourcePersistence {
  Future<HomeSource> read();
  Future<void> write(HomeSource source);
}

class HomeSourceException implements Exception {
  const HomeSourceException(this.code);

  final String code;

  @override
  String toString() => 'HomeSourceException($code)';
}

class SharedPreferencesHomeSourceStore implements HomeSourcePersistence {
  SharedPreferencesHomeSourceStore({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _loadPreferences;
  static const key = 'home_source_v1';

  @override
  Future<HomeSource> read() => ConfigurationWrites.run(() async {
    try {
      final preferences = await _loadPreferences();
      // Legacy SharedPreferences updates its cache before persistence succeeds.
      // Reload keeps a rejected write from becoming the next source of truth.
      await preferences.reload();
      return switch (preferences.get(key)) {
        null => HomeSource.directLocal,
        'directLocal' => HomeSource.directLocal,
        'verifiedCore' => HomeSource.verifiedCore,
        _ => throw const HomeSourceException('source_read_failed'),
      };
    } catch (_) {
      throw const HomeSourceException('source_read_failed');
    }
  });

  @override
  Future<void> write(HomeSource source) => ConfigurationWrites.run(() async {
    try {
      final preferences = await _loadPreferences();
      if (!await preferences.setString(key, source.name)) {
        throw const HomeSourceException('source_write_failed');
      }
    } catch (_) {
      throw const HomeSourceException('source_write_failed');
    }
  });
}
