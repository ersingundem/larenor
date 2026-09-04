import 'package:larenor/core/configuration_writes.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_service.dart';

/// Persists which optional services are toggled on, independent of whether
/// they're connected — disabling a service only hides it, it doesn't clear
/// its saved credentials, so re-enabling it doesn't require reconnecting.
class EnabledServicesStore {
  static const _key = 'enabled_services';

  Future<Set<AppService>> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key);
    if (raw == null) return {};
    return raw
        .map(
          (name) => AppService.values.where((s) => s.name == name).firstOrNull,
        )
        .whereType<AppService>()
        .toSet();
  }

  Future<void> save(Set<AppService> services, {bool markMigrated = false}) =>
      ConfigurationWrites.run(() async {
        final prefs = await SharedPreferences.getInstance();
        if (!await prefs.setStringList(
          _key,
          services.map((s) => s.name).toList(),
        )) {
          throw StateError('Enabled services could not be saved.');
        }
        if (markMigrated &&
            !await prefs.setBool('enabled_services_migrated', true)) {
          throw StateError('Service migration could not be saved.');
        }
      });
}
