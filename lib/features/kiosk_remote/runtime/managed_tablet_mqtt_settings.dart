import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'mqtt_local_broker.dart';

abstract interface class ManagedTabletMqttSettingsStore {
  Future<LocalMqttBrokerSettings> read();

  Future<void> write(LocalMqttBrokerSettings settings);

  Future<void> replaceIfExact(
    LocalMqttBrokerSettings expected,
    LocalMqttBrokerSettings replacement,
  );
}

final class SharedPreferencesManagedTabletMqttSettingsStore
    implements ManagedTabletMqttSettingsStore {
  static const preferenceKey = 'managed_tablet_mqtt_settings_v1';
  static const _keys = {'schemaVersion', 'enabled', 'host', 'port', 'tls'};

  @override
  Future<LocalMqttBrokerSettings> read() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(preferenceKey);
    if (raw == null) return LocalMqttBrokerSettings.disabled();
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> ||
          value.keys.toSet().difference(_keys).isNotEmpty ||
          _keys.difference(value.keys.toSet()).isNotEmpty ||
          value['schemaVersion'] != 1 ||
          value['enabled'] is! bool ||
          value['host'] is! String ||
          value['port'] is! int ||
          value['tls'] != true) {
        return LocalMqttBrokerSettings.disabled();
      }
      return LocalMqttBrokerSettings(
        enabled: value['enabled'] as bool,
        host: value['host'] as String,
        port: value['port'] as int,
        tls: true,
      );
    } catch (_) {
      return LocalMqttBrokerSettings.disabled();
    }
  }

  @override
  Future<void> write(LocalMqttBrokerSettings settings) async {
    _assertSecure(settings);
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(
      preferenceKey,
      jsonEncode({'schemaVersion': 1, ...settings.publicMetadata}),
    );
    if (!saved) throw StateError('mqtt_settings_storage_failed');
  }

  @override
  Future<void> replaceIfExact(
    LocalMqttBrokerSettings expected,
    LocalMqttBrokerSettings replacement,
  ) async {
    if (await read() != expected) return;
    await write(replacement);
  }

  static void _assertSecure(LocalMqttBrokerSettings settings) {
    if (!settings.tls) throw StateError('mqtt_tls_required');
  }
}

final class ManagedTabletMqttSettingsRepository {
  ManagedTabletMqttSettingsRepository(this.store);

  final ManagedTabletMqttSettingsStore store;
  Future<void> _operations = Future.value();

  Future<LocalMqttBrokerSettings> read() => store.read();

  Future<LocalMqttBrokerSettings> save(
    LocalMqttBrokerSettings settings, {
    required bool Function() isCurrent,
    void Function(LocalMqttBrokerSettings settings)? publish,
  }) {
    final operation = _operations.then((_) async {
      if (!_current(isCurrent)) {
        throw StateError('mqtt_settings_write_retired');
      }
      final previous = await store.read();
      if (!_current(isCurrent)) {
        throw StateError('mqtt_settings_write_retired');
      }
      await store.write(settings);
      if (!_current(isCurrent)) {
        await store.replaceIfExact(settings, previous);
        throw StateError('mqtt_settings_write_retired');
      }
      try {
        publish?.call(settings);
      } catch (_) {
        await store.replaceIfExact(settings, previous);
        rethrow;
      }
      return settings;
    });
    _operations = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  static bool _current(bool Function() guard) {
    try {
      return guard();
    } catch (_) {
      return false;
    }
  }
}
