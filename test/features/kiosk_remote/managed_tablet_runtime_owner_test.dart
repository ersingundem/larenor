import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_credential_store.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_mqtt_runtime.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_runtime_owner.dart';
import 'package:larenor/features/kiosk_remote/runtime/mqtt_local_broker.dart';
import 'package:larenor/features/kiosk_remote/runtime/native_managed_tablet_source.dart';

const _token = 'fixture-token-fixture-token-fixture-token-1';

ManagedTabletEnrollment _enrollment() => ManagedTabletEnrollment(
  serverBaseUrl: 'https://core.invalid',
  coreId: '1' * 32,
  homeId: '2' * 32,
  accountId: '3' * 32,
  pairingId: '4' * 32,
  deviceId: '5' * 32,
  revision: 1,
  scopes: const {'read', 'control'},
  expiresAt: DateTime.utc(2030),
  token: _token,
  clientId: 'larenor-${'4' * 32}',
  topicPrefix: 'larenor/${'4' * 32}',
);

final class _Store implements ManagedTabletCredentialStore {
  _Store(this.value);
  ManagedTabletEnrollment? value;
  int clears = 0;
  Completer<void>? writeStarted, writeGate;
  @override
  Future<ManagedTabletEnrollment?> read() async => value;
  @override
  Future<void> write(ManagedTabletEnrollment value) async {
    final started = writeStarted;
    if (started != null && !started.isCompleted) started.complete();
    await writeGate?.future;
    this.value = value;
  }

  @override
  Future<void> clearIfCurrent(
    ManagedTabletBinding binding,
    String pairingId,
  ) async {
    if (value?.binding == binding && value?.pairingId == pairingId) {
      value = null;
      clears++;
    }
  }

  @override
  Future<void> clearIfExact(ManagedTabletEnrollment enrollment) async {
    if (value?.binding == enrollment.binding &&
        value?.pairingId == enrollment.pairingId &&
        value?.revision == enrollment.revision) {
      value = null;
      clears++;
    }
  }
}

final class _Authority implements ManagedTabletCoreAuthority {
  int calls = 0;
  Completer<void>? gate;
  Object? failure;
  @override
  Future<void> verify(
    ManagedTabletBinding binding,
    ManagedTabletEnrollment enrollment,
  ) async {
    calls++;
    await gate?.future;
    if (failure case final error?) throw error;
  }
}

final class _Lease implements NativeManagedTabletSourceLease {
  @override
  final commandExecutor = _DisabledExecutor();
  @override
  Future<ManagedTabletTelemetry> readTelemetry() async =>
      const ManagedTabletTelemetry(
        batteryPercent: 75,
        network: 'wifi',
        appVersion: '1.0.0',
        appForeground: true,
        kioskState: 'foreground',
      );
}

final class _DisabledExecutor implements ManagedTabletCommandExecutor {
  @override
  Future<ManagedTabletCommandResult> execute(String kind) async =>
      ManagedTabletCommandResult.unsupported;
}

final class _Source implements ManagedTabletSourcePort {
  int binds = 0, retires = 0;
  @override
  Future<NativeManagedTabletSourceLease?> bind(String scope) async {
    binds++;
    return _Lease();
  }

  @override
  Future<void> retire() async => retires++;
  @override
  Future<void> setForeground(bool value) async {
    if (!value) await retire();
  }
}

final class _Broker implements LocalMqttBroker {
  int connects = 0, disconnects = 0;
  String? password;
  Completer<void>? connectGate;
  final connectStarted = Completer<void>();
  @override
  Future<void> connect({
    required LocalMqttBrokerSettings settings,
    required String clientId,
    required String username,
    required String password,
    required BrokerMessageHandler onMessage,
    required BrokerDisconnectHandler onDisconnected,
  }) async {
    connects++;
    this.password = password;
    if (!connectStarted.isCompleted) connectStarted.complete();
    await connectGate?.future;
  }

  @override
  Future<void> disconnect() async => disconnects++;
  @override
  Future<void> publish(
    String topic,
    List<int> payload, {
    required bool retained,
  }) async {}
  @override
  Future<void> subscribe(String topic) async {}
}

ManagedTabletRuntimeOwner _owner({
  required _Store store,
  required _Authority authority,
  required _Source source,
  required _Broker broker,
}) => ManagedTabletRuntimeOwner(
  store: store,
  authority: authority,
  source: source,
  broker: broker,
  settings: LocalMqttBrokerSettings(
    enabled: true,
    host: 'mqtt.home.arpa',
    port: 8883,
    tls: true,
  ),
  stateStore: MemoryManagedMqttStateStore(),
  now: () => DateTime.utc(2029),
);

void main() {
  test(
    'explicit enrollment starts only for the exact current binding',
    () async {
      final enrollment = _enrollment();
      final store = _Store(null);
      final authority = _Authority();
      final source = _Source();
      final broker = _Broker();
      final owner = _owner(
        store: store,
        authority: authority,
        source: source,
        broker: broker,
      );
      addTearDown(owner.dispose);
      await owner.updateBinding(enrollment.binding);
      expect(broker.connects, 0);

      await owner.enroll(enrollment.binding, enrollment);

      expect(store.value?.pairingId, enrollment.pairingId);
      expect(authority.calls, 2);
      expect(source.binds, 1);
      expect(broker.connects, 1);
    },
  );

  test('explicit enrollment rejects a non-current account binding', () async {
    final enrollment = _enrollment();
    final store = _Store(null);
    final owner = _owner(
      store: store,
      authority: _Authority(),
      source: _Source(),
      broker: _Broker(),
    );
    addTearDown(owner.dispose);
    await owner.updateBinding(
      ManagedTabletBinding(
        serverBaseUrl: enrollment.serverBaseUrl,
        coreId: enrollment.coreId,
        homeId: enrollment.homeId,
        accountId: '9' * 32,
      ),
    );

    await expectLater(
      owner.enroll(enrollment.binding, enrollment),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'managed_tablet_enrollment_denied',
        ),
      ),
    );

    expect(store.value, isNull);
  });

  test(
    'account change during secure write removes the retired record',
    () async {
      final enrollment = _enrollment();
      final store = _Store(null)
        ..writeStarted = Completer<void>()
        ..writeGate = Completer<void>();
      final owner = _owner(
        store: store,
        authority: _Authority(),
        source: _Source(),
        broker: _Broker(),
      );
      addTearDown(owner.dispose);
      await owner.updateBinding(enrollment.binding);

      final pending = owner.enroll(enrollment.binding, enrollment);
      await store.writeStarted!.future;
      await owner.updateBinding(
        ManagedTabletBinding(
          serverBaseUrl: enrollment.serverBaseUrl,
          coreId: enrollment.coreId,
          homeId: enrollment.homeId,
          accountId: '9' * 32,
        ),
      );
      store.writeGate!.complete();

      await expectLater(
        pending,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'managed_tablet_enrollment_retired',
          ),
        ),
      );
      expect(store.value, isNull);
      expect(store.clears, 1);
    },
  );

  test(
    'route retirement during secure write clears the record before connect',
    () async {
      final enrollment = _enrollment();
      final store = _Store(null)
        ..writeStarted = Completer<void>()
        ..writeGate = Completer<void>();
      final broker = _Broker();
      final owner = _owner(
        store: store,
        authority: _Authority(),
        source: _Source(),
        broker: broker,
      );
      addTearDown(owner.dispose);
      await owner.updateBinding(enrollment.binding);
      var routeCurrent = true;

      final pending = owner.enroll(
        enrollment.binding,
        enrollment,
        isCurrent: () => routeCurrent,
      );
      await store.writeStarted!.future;
      routeCurrent = false;
      store.writeGate!.complete();

      await expectLater(
        pending,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'managed_tablet_enrollment_retired',
          ),
        ),
      );
      expect(store.value, isNull);
      expect(store.clears, 1);
      expect(broker.connects, 0);
    },
  );

  test('current Core and egress are rechecked before broker connect', () async {
    final enrollment = _enrollment();
    final store = _Store(enrollment);
    final authority = _Authority();
    final source = _Source();
    final broker = _Broker();
    final owner = _owner(
      store: store,
      authority: authority,
      source: source,
      broker: broker,
    );
    addTearDown(owner.dispose);

    await owner.updateBinding(enrollment.binding);

    expect(authority.calls, 2);
    expect(source.binds, 1);
    expect(broker.connects, 1);
    expect(broker.password, _token);
    expect(jsonEncode(enrollment.publicMetadata), isNot(contains(_token)));
  });

  test(
    'background and account change retire old runtime before reuse',
    () async {
      final enrollment = _enrollment();
      final store = _Store(enrollment);
      final authority = _Authority();
      final source = _Source();
      final broker = _Broker();
      final owner = _owner(
        store: store,
        authority: authority,
        source: source,
        broker: broker,
      );
      addTearDown(owner.dispose);
      await owner.updateBinding(enrollment.binding);

      await owner.setForeground(false);
      expect(broker.disconnects, 1);
      await owner.setForeground(true);
      expect(broker.connects, 2);
      await owner.updateBinding(
        ManagedTabletBinding(
          serverBaseUrl: enrollment.serverBaseUrl,
          coreId: enrollment.coreId,
          homeId: enrollment.homeId,
          accountId: '9' * 32,
        ),
      );

      expect(broker.disconnects, 2);
      expect(broker.connects, 2);
    },
  );

  test('saved broker replacement retires before reconnecting', () async {
    final enrollment = _enrollment();
    final store = _Store(enrollment);
    final broker = _Broker();
    final owner = _owner(
      store: store,
      authority: _Authority(),
      source: _Source(),
      broker: broker,
    );
    addTearDown(owner.dispose);
    await owner.updateBinding(enrollment.binding);

    await owner.updateSettings(
      LocalMqttBrokerSettings(
        enabled: true,
        host: 'mqtt-backup.home.arpa',
        port: 8884,
        tls: true,
      ),
    );

    expect(broker.disconnects, 1);
    expect(broker.connects, 2);
  });

  test('disabling saved broker retires without reconnecting', () async {
    final enrollment = _enrollment();
    final store = _Store(enrollment);
    final broker = _Broker();
    final owner = _owner(
      store: store,
      authority: _Authority(),
      source: _Source(),
      broker: broker,
    );
    addTearDown(owner.dispose);
    await owner.updateBinding(enrollment.binding);

    await owner.updateSettings(LocalMqttBrokerSettings.disabled());

    expect(broker.disconnects, 1);
    expect(broker.connects, 1);
  });

  test(
    'logout during delayed Core verification cannot connect later',
    () async {
      final enrollment = _enrollment();
      final store = _Store(enrollment);
      final authority = _Authority()..gate = Completer<void>();
      final source = _Source();
      final broker = _Broker();
      final owner = _owner(
        store: store,
        authority: authority,
        source: source,
        broker: broker,
      );
      addTearDown(owner.dispose);

      final pending = owner.updateBinding(enrollment.binding);
      await Future<void>.delayed(Duration.zero);
      final logout = owner.updateBinding(null);
      authority.gate!.complete();
      await Future.wait([pending, logout]);

      expect(broker.connects, 0);
      expect(source.retires, greaterThanOrEqualTo(1));
    },
  );

  test(
    'Core revoke clears exact secure enrollment and stays disconnected',
    () async {
      final enrollment = _enrollment();
      final store = _Store(enrollment);
      final authority = _Authority()..failure = const ManagedTabletRevoked();
      final source = _Source();
      final broker = _Broker();
      final owner = _owner(
        store: store,
        authority: authority,
        source: source,
        broker: broker,
      );
      addTearDown(owner.dispose);

      await owner.updateBinding(enrollment.binding);

      expect(store.value, isNull);
      expect(store.clears, 1);
      expect(broker.connects, 0);
    },
  );

  test(
    'unrelated pairing revoke leaves the active runtime connected',
    () async {
      final enrollment = _enrollment();
      final store = _Store(enrollment);
      final authority = _Authority();
      final source = _Source();
      final broker = _Broker();
      final owner = _owner(
        store: store,
        authority: authority,
        source: source,
        broker: broker,
      );
      addTearDown(owner.dispose);
      await owner.updateBinding(enrollment.binding);

      await owner.revoke('9' * 32);

      expect(store.value?.pairingId, enrollment.pairingId);
      expect(broker.disconnects, 0);
      expect(broker.connects, 1);
    },
  );

  test(
    'logout disconnects a pending broker connect before it returns',
    () async {
      final enrollment = _enrollment();
      final store = _Store(enrollment);
      final authority = _Authority();
      final source = _Source();
      final broker = _Broker()..connectGate = Completer<void>();
      final owner = _owner(
        store: store,
        authority: authority,
        source: source,
        broker: broker,
      );
      addTearDown(owner.dispose);

      final pending = owner.updateBinding(enrollment.binding);
      await broker.connectStarted.future;
      final logout = owner.updateBinding(null);
      await Future<void>.delayed(Duration.zero);

      expect(broker.disconnects, 1);
      broker.connectGate!.complete();
      await Future.wait([pending, logout]);
      expect(broker.connects, 1);
    },
  );
}
