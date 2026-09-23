import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk_remote/presentation/kiosk_remote_screen.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_mqtt_settings.dart';
import 'package:larenor/features/kiosk_remote/runtime/mqtt_local_broker.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
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

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets(
        'broker editor ${locale.languageCode} $width 2x saves explicitly',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1200);
          addTearDown(tester.view.reset);
          final saved = <LocalMqttBrokerSettings>[];
          await tester.pumpWidget(
            CupertinoApp(
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: CupertinoPageScaffold(
                child: ListView(
                  children: [
                    MqttBrokerSettingsEditor(
                      settings: LocalMqttBrokerSettings.disabled(),
                      onSave: (value) async => saved.add(value),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.enterText(
            find.byKey(const ValueKey('mqtt-broker-host')),
            'mqtt.home.arpa',
          );
          await tester.tap(find.byKey(const ValueKey('mqtt-broker-enabled')));
          expect(saved, isEmpty);

          final save = find.byKey(const ValueKey('mqtt-broker-save'));
          await tester.ensureVisible(save);
          await tester.pumpAndSettle();
          expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
          await tester.tap(save);
          await tester.pumpAndSettle();

          expect(saved, hasLength(1));
          expect(saved.single.enabled, isTrue);
          expect(saved.single.host, 'mqtt.home.arpa');
          expect(saved.single.port, 8883);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
