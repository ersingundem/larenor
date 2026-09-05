import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/direct_home_access.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_service.dart';

/// Persists which optional services are toggled on, independent of whether
/// they're connected — disabling a service only hides it, it doesn't clear
/// its saved credentials, so re-enabling it doesn't require reconnecting.
class EnabledServicesStore {
  // Keep the public parameter name while the ownership field stays private.
  // ignore: prefer_initializing_formals
  EnabledServicesStore({DirectHomeAccess? access}) : _access = access;
  final DirectHomeAccess? _access;
  static const _key = 'enabled_services';
  void _check() => _access?.check();
  Future<T> _call<T>(Future<T> Function() operation, {bool mutation = false}) =>
      _access?.storage(operation, mutation: mutation) ?? operation();
  Future<SharedPreferences> _preferences() async {
    _check();
    final prefs = await _call(SharedPreferences.getInstance);
    await _call(prefs.reload);
    _check();
    return prefs;
  }

  Future<bool> migrationComplete() => ConfigurationWrites.run(() async {
    final prefs = await _preferences();
    _check();
    return prefs.getBool('enabled_services_migrated') ?? false;
  });

  Future<Set<AppService>> read() => ConfigurationWrites.run(() async {
    final prefs = await _preferences();
    _check();
    final raw = prefs.getStringList(_key);
    if (raw == null) return {};
    return raw
        .map(
          (name) => AppService.values.where((s) => s.name == name).firstOrNull,
        )
        .whereType<AppService>()
        .toSet();
  });

  Future<void> save(Set<AppService> services, {bool markMigrated = false}) =>
      ConfigurationWrites.run(() async {
        final prefs = await _preferences();
        _check();
        if (!await _call(
          () => prefs.setStringList(_key, services.map((s) => s.name).toList()),
          mutation: true,
        )) {
          throw StateError('Enabled services could not be saved.');
        }
        if (markMigrated &&
            !await _call(
              () => prefs.setBool('enabled_services_migrated', true),
              mutation: true,
            )) {
          throw StateError('Service migration could not be saved.');
        }
        _check();
      });
}
