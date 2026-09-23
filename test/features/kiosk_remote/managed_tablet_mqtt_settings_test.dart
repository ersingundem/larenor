import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_mqtt_settings.dart';
import 'package:larenor/features/kiosk_remote/runtime/mqtt_local_broker.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _DelayedStore implements ManagedTabletMqttSettingsStore {
  _DelayedStore(this.value);

  LocalMqttBrokerSettings value;
  final writeStarted = Completer<void>();
  final writeGate = Completer<void>();

  @override
  Future<LocalMqttBrokerSettings> read() async => value;

  @override
  Future<void> write(LocalMqttBrokerSettings settings) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate.future;
    value = settings;
  }

  @override
  Future<void> replaceIfExact(
    LocalMqttBrokerSettings expected,
    LocalMqttBrokerSettings replacement,
  ) async {
    if (value == expected) value = replacement;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'strict public broker settings round-trip without credentials',
    () async {
      final store = SharedPreferencesManagedTabletMqttSettingsStore();
      final settings = LocalMqttBrokerSettings(
        enabled: true,
        host: 'mqtt.home.arpa',
        port: 8883,
        tls: true,
      );

      await store.write(settings);

      expect(await store.read(), settings);
      final raw = (await SharedPreferences.getInstance()).getString(
        SharedPreferencesManagedTabletMqttSettingsStore.preferenceKey,
      );
      expect(jsonDecode(raw!), {
        'schemaVersion': 1,
        'enabled': true,
        'host': 'mqtt.home.arpa',
        'port': 8883,
        'tls': true,
      });
      expect(raw, isNot(contains('token')));
      expect(raw, isNot(contains('password')));
    },
  );

  test(
    'unknown, malformed, or insecure persisted values fail closed',
    () async {
      for (final value in <Object?>[
        7,
        {
          'schemaVersion': 2,
          'enabled': true,
          'host': 'mqtt.home.arpa',
          'port': 8883,
          'tls': true,
        },
        {
          'schemaVersion': 1,
          'enabled': true,
          'host': 'mqtt.home.arpa',
          'port': 8883,
          'tls': false,
        },
        {
          'schemaVersion': 1,
          'enabled': true,
          'host': 'https://evil.invalid',
          'port': 8883,
          'tls': true,
        },
        {
          'schemaVersion': 1,
          'enabled': true,
          'host': 'mqtt.home.arpa',
          'port': 8883,
          'tls': true,
          'secret': 'x',
        },
      ]) {
        SharedPreferences.setMockInitialValues({
          SharedPreferencesManagedTabletMqttSettingsStore.preferenceKey:
              jsonEncode(value),
        });
        final restored = await SharedPreferencesManagedTabletMqttSettingsStore()
            .read();
        expect(restored, LocalMqttBrokerSettings.disabled());
      }
    },
  );

  test(
    'late save after route retirement restores exact previous value',
    () async {
      final previous = LocalMqttBrokerSettings.disabled();
      final next = LocalMqttBrokerSettings(
        enabled: true,
        host: 'mqtt.home.arpa',
        port: 8883,
        tls: true,
      );
      final store = _DelayedStore(previous);
      final repository = ManagedTabletMqttSettingsRepository(store);
      var current = true;

      final pending = repository.save(next, isCurrent: () => current);
      await store.writeStarted.future;
      current = false;
      store.writeGate.complete();

      await expectLater(pending, throwsStateError);
      expect(store.value, previous);
    },
  );
}
