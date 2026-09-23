import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_mqtt_runtime.dart';
import 'package:larenor/features/kiosk_remote/runtime/mqtt_local_broker.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _token = 'fixture-token-fixture-token-fixture-token-1';
const _pairingId = '22222222222222222222222222222222';
const _deviceId = '11111111111111111111111111111111';
const _prefix = 'larenor/$_pairingId';

ManagedTabletPairingCredential pairing({
  Set<String> scopes = const {'read', 'control'},
  bool active = true,
}) => ManagedTabletPairingCredential(
  pairingId: _pairingId,
  deviceId: _deviceId,
  revision: active ? 1 : 2,
  scopes: scopes,
  expiresAt: DateTime.utc(2030),
  active: active,
  token: _token,
  clientId: 'larenor-$_pairingId',
  topicPrefix: _prefix,
);

const telemetry = ManagedTabletTelemetry(
  batteryPercent: 73,
  network: 'wifi',
  appVersion: '1.0.0+1',
  appForeground: true,
  kioskState: 'foreground',
);

final class _Broker implements LocalMqttBroker {
  int connectCalls = 0;
  int disconnectCalls = 0;
  final subscriptions = <String>[];
  final publications = <({String topic, String payload, bool retained})>[];
  BrokerMessageHandler? messages;
  BrokerDisconnectHandler? disconnected;
  String? username;
  String? password;
  Completer<void>? connectGate;
  final connectGates = <Completer<void>>[];
  Object? subscribeFailure;

  @override
  Future<void> connect({
    required LocalMqttBrokerSettings settings,
    required String clientId,
    required String username,
    required String password,
    required BrokerMessageHandler onMessage,
    required BrokerDisconnectHandler onDisconnected,
  }) async {
    final attempt = connectCalls++;
    this.username = username;
    this.password = password;
    messages = onMessage;
    disconnected = onDisconnected;
    if (attempt < connectGates.length) {
      await connectGates[attempt].future;
    } else {
      await connectGate?.future;
    }
  }

  @override
  Future<void> disconnect() async => disconnectCalls++;

  @override
  Future<void> publish(
    String topic,
    List<int> payload, {
    required bool retained,
  }) async => publications.add((
    topic: topic,
    payload: utf8.decode(payload),
    retained: retained,
  ));

  @override
  Future<void> subscribe(String topic) async {
    if (subscribeFailure case final failure?) throw failure;
    subscriptions.add(topic);
  }

  Future<void> deliver(Map<String, Object?> body, {bool retained = false}) =>
      messages!(
        BrokerMessage(
          topic: '$_prefix/command',
          payload: utf8.encode(jsonEncode(body)),
          retained: retained,
        ),
      );

  Future<void> deliverRaw(String payload, {bool retained = false}) => messages!(
    BrokerMessage(
      topic: '$_prefix/command',
      payload: utf8.encode(payload),
      retained: retained,
    ),
  );

  void loseConnection() => disconnected!();
}

final class _Executor implements ManagedTabletCommandExecutor {
  final calls = <String>[];

  @override
  Future<ManagedTabletCommandResult> execute(String kind) async {
    calls.add(kind);
    return ManagedTabletCommandResult.succeeded;
  }
}

final class _GatedStore implements ManagedMqttStateStore {
  _GatedStore({this.readGate, this.writeGate, this.gatedWriteNumber = 1});

  final Completer<void>? readGate;
  final Completer<void>? writeGate;
  final int gatedWriteNumber;
  final readStarted = Completer<void>();
  final writeStarted = Completer<void>();
  ManagedMqttCommandState value = const ManagedMqttCommandState.empty();
  int writes = 0;

  @override
  Future<ManagedMqttCommandState> read(String pairingId) async {
    if (!readStarted.isCompleted) readStarted.complete();
    await readGate?.future;
    return value;
  }

  @override
  Future<void> write(String pairingId, ManagedMqttCommandState state) async {
    writes += 1;
    if (writes == gatedWriteNumber) {
      if (!writeStarted.isCompleted) writeStarted.complete();
      await writeGate?.future;
    }
    value = state;
  }
}

Map<String, Object?> command({
  int sequence = 1,
  String requestId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  String kind = 'refreshDashboard',
}) => {
  'schemaVersion': 1,
  'requestId': requestId,
  'sequence': sequence,
  'kind': kind,
  'retained': false,
  'expiresAt': DateTime.utc(2029, 1, 1, 0, 4).millisecondsSinceEpoch / 1000,
};

ManagedTabletMqttRuntime _runtime({
  required _Broker broker,
  required ManagedMqttStateStore store,
  required _Executor executor,
  required Future<ManagedTabletPairingCredential> Function() authority,
  bool enabled = true,
  List<String>? logs,
  int maxCommandsPerMinute = 30,
  Future<void> Function(LocalMqttBrokerSettings)? onEgress,
  Future<ManagedTabletTelemetry> Function()? telemetryReader,
}) => ManagedTabletMqttRuntime(
  broker: broker,
  settings: LocalMqttBrokerSettings(
    enabled: enabled,
    host: 'mqtt.home.arpa',
    port: 8883,
    tls: true,
  ),
  authority: authority,
  telemetry: telemetryReader ?? () async => telemetry,
  executor: executor,
  stateStore: store,
  authorizeEgress: onEgress ?? (_) async {},
  now: () => DateTime.utc(2029),
  logger: logs?.add,
  maxCommandsPerMinute: maxCommandsPerMinute,
);

Map<String, dynamic> _lastAck(_Broker broker) => jsonDecode(
  broker.publications
      .lastWhere((entry) => entry.topic == '$_prefix/ack')
      .payload,
) as Map<String, dynamic>;

void main() {
  test(
    'default-disabled runtime opens no broker and never exports its token',
    () async {
      final broker = _Broker();
      final logs = <String>[];
      final credential = pairing();
      final subject = _runtime(
        broker: broker,
        store: MemoryManagedMqttStateStore(),
        executor: _Executor(),
        authority: () async => credential,
        enabled: false,
        logs: logs,
      );

      await subject.start();

      expect(subject.status, ManagedTabletMqttStatus.disabled);
      expect(broker.connectCalls, 0);
      expect(jsonEncode(credential.publicMetadata), isNot(contains(_token)));
      expect(credential.toString(), isNot(contains(_token)));
      expect(logs.join(), isNot(contains(_token)));
    },
  );

  test(
    'read-only telemetry can refresh and explicit retirement disconnects',
    () async {
      final broker = _Broker();
      final subject = _runtime(
        broker: broker,
        store: MemoryManagedMqttStateStore(),
        executor: _Executor(),
        authority: () async => pairing(scopes: const {'read'}),
      );
      await subject.start();
      expect(broker.subscriptions, isEmpty);
      final before = broker.publications.length;
      await subject.refreshTelemetry();
      expect(broker.publications.length, before + 5);
      await subject.retire();
      expect(subject.status, ManagedTabletMqttStatus.retired);
      expect(broker.disconnectCalls, 1);
    },
  );

  test('malformed, retained, expired and old commands fail closed', () async {
    final broker = _Broker();
    final executor = _Executor();
    final subject = _runtime(
      broker: broker,
      store: MemoryManagedMqttStateStore(),
      executor: executor,
      authority: () async => pairing(),
    );
    await subject.start();
    await broker.deliverRaw('{');
    expect(_lastAck(broker)['error'], 'invalid_mqtt_command');
    await broker.deliver(command(), retained: true);
    expect(_lastAck(broker)['error'], 'mqtt_retained_command_denied');
    await broker.deliver({
      ...command(),
      'expiresAt': DateTime.utc(2028).millisecondsSinceEpoch / 1000,
    });
    expect(_lastAck(broker)['error'], 'mqtt_command_expired');
    await broker.deliver(command(sequence: 2));
    await broker.deliver(
      command(sequence: 1, requestId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
    );
    expect(_lastAck(broker)['error'], 'mqtt_command_replay');
    expect(executor.calls, ['refreshDashboard']);
  });

  test(
    'pending command recovered after restart is not executed again',
    () async {
      final body = command();
      final payload = utf8.encode(jsonEncode(body));
      final store = MemoryManagedMqttStateStore();
      await store.write(
        _pairingId,
        ManagedMqttCommandState(
          sequence: 1,
          requestId: body['requestId']! as String,
          digest: sha256.convert(payload).toString(),
          pending: true,
          result: null,
          error: null,
          acceptedAtMs: [DateTime.utc(2029).millisecondsSinceEpoch],
        ),
      );
      final broker = _Broker();
      final executor = _Executor();
      final subject = _runtime(
        broker: broker,
        store: store,
        executor: executor,
        authority: () async => pairing(),
      );
      await subject.start();
      await broker.deliver(body);
      expect(executor.calls, isEmpty);
      expect(_lastAck(broker), containsPair('error', 'execution_unconfirmed'));
      expect(_lastAck(broker)['replayed'], isTrue);
    },
  );

  test(
    'shared preferences state survives a new store and rejects corruption',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = ManagedMqttCommandState(
        sequence: 2,
        requestId: 'a' * 32,
        digest: 'b' * 64,
        pending: false,
        result: 'succeeded',
        error: null,
        acceptedAtMs: [1, 2],
      );
      await SharedPreferencesManagedMqttStateStore().write(_pairingId, state);
      final restored = await SharedPreferencesManagedMqttStateStore().read(
        _pairingId,
      );
      expect(restored.toJson(), state.toJson());

      SharedPreferences.setMockInitialValues({
        '${SharedPreferencesManagedMqttStateStore.keyPrefix}$_pairingId': '{}',
      });
      expect(
        SharedPreferencesManagedMqttStateStore().read(_pairingId),
        throwsFormatException,
      );
    },
  );

  test('inactive authority starts revoked without opening a broker', () async {
    final broker = _Broker();
    final subject = _runtime(
      broker: broker,
      store: MemoryManagedMqttStateStore(),
      executor: _Executor(),
      authority: () async => pairing(active: false),
    );
    await subject.start();
    expect(subject.status, ManagedTabletMqttStatus.revoked);
    expect(broker.connectCalls, 0);
  });

  test(
    'telemetry, command ack, replay, rate limit and restart stay bounded',
    () async {
      final store = MemoryManagedMqttStateStore();
      final firstBroker = _Broker();
      final firstExecutor = _Executor();
      final first = _runtime(
        broker: firstBroker,
        store: store,
        executor: firstExecutor,
        authority: () async => pairing(),
        maxCommandsPerMinute: 2,
      );

      await first.start();
      expect(first.status, ManagedTabletMqttStatus.connected);
      expect(firstBroker.username, _pairingId);
      expect(firstBroker.password, _token);
      expect(firstBroker.subscriptions, ['$_prefix/command']);
      expect(
        firstBroker.publications
            .where((entry) => entry.topic.contains('/sensor/'))
            .map((entry) => entry.topic)
            .toSet(),
        {
          '$_prefix/sensor/battery/state',
          '$_prefix/sensor/network/state',
          '$_prefix/sensor/app_version/state',
          '$_prefix/sensor/app_foreground/state',
          '$_prefix/sensor/kiosk_state/state',
        },
      );
      expect(
        firstBroker.publications
            .where((entry) => entry.topic.contains('/sensor/'))
            .every((entry) => entry.retained),
        isTrue,
      );

      final firstCommand = command();
      await firstBroker.deliver(firstCommand);
      await firstBroker.deliver(firstCommand);
      expect(firstExecutor.calls, ['refreshDashboard']);
      expect(_lastAck(firstBroker)['replayed'], isTrue);

      final restartedBroker = _Broker();
      final restartedExecutor = _Executor();
      final restarted = _runtime(
        broker: restartedBroker,
        store: store,
        executor: restartedExecutor,
        authority: () async => pairing(),
        maxCommandsPerMinute: 2,
      );
      await restarted.start();
      await restartedBroker.deliver(firstCommand);
      expect(restartedExecutor.calls, isEmpty);
      expect(_lastAck(restartedBroker)['replayed'], isTrue);

      await restartedBroker.deliver(
        command(sequence: 1, requestId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
      );
      expect(_lastAck(restartedBroker)['error'], 'mqtt_command_conflict');
      await restartedBroker.deliver(
        command(sequence: 2, requestId: 'cccccccccccccccccccccccccccccccc'),
      );
      await restartedBroker.deliver(
        command(sequence: 3, requestId: 'dddddddddddddddddddddddddddddddd'),
      );
      expect(_lastAck(restartedBroker)['error'], 'rate_limited');
      expect(restartedExecutor.calls, ['refreshDashboard']);
    },
  );

  test(
    'broker restart reconnects without command replay and revoke retires',
    () async {
      var credential = pairing();
      var egressChecks = 0;
      final broker = _Broker();
      final executor = _Executor();
      final subject = _runtime(
        broker: broker,
        store: MemoryManagedMqttStateStore(),
        executor: executor,
        authority: () async => credential,
        onEgress: (_) async => egressChecks++,
      );
      await subject.start();
      await broker.deliver(command());
      broker.loseConnection();
      expect(subject.status, ManagedTabletMqttStatus.disconnected);

      await subject.reconnect();
      expect(broker.connectCalls, 2);
      expect(egressChecks, 2);
      expect(executor.calls, ['refreshDashboard']);

      credential = pairing(active: false);
      await broker.deliver(
        command(sequence: 2, requestId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
      );
      expect(subject.status, ManagedTabletMqttStatus.revoked);
      expect(broker.disconnectCalls, 1);
      expect(executor.calls, ['refreshDashboard']);
    },
  );

  test(
    'admin-only command is denied for control scope before execution',
    () async {
      final broker = _Broker();
      final executor = _Executor();
      final subject = _runtime(
        broker: broker,
        store: MemoryManagedMqttStateStore(),
        executor: executor,
        authority: () async => pairing(),
      );
      await subject.start();
      await broker.deliver(command(kind: 'lockKiosk'));
      expect(_lastAck(broker)['error'], 'pairing_scope_denied');
      expect(executor.calls, isEmpty);
    },
  );

  test(
    'retire wins over delayed authority and cannot reopen the broker',
    () async {
      final authority = Completer<ManagedTabletPairingCredential>();
      final broker = _Broker();
      final subject = _runtime(
        broker: broker,
        store: MemoryManagedMqttStateStore(),
        executor: _Executor(),
        authority: () => authority.future,
      );

      final start = subject.start();
      await Future<void>.delayed(Duration.zero);
      await subject.retire();
      authority.complete(pairing());
      await start;

      expect(subject.status, ManagedTabletMqttStatus.retired);
      expect(broker.connectCalls, 0);
      expect(broker.publications, isEmpty);
    },
  );

  test(
    'retire during connect disconnects late success without publishing',
    () async {
      final broker = _Broker()..connectGate = Completer<void>();
      final subject = _runtime(
        broker: broker,
        store: MemoryManagedMqttStateStore(),
        executor: _Executor(),
        authority: () async => pairing(),
      );

      final start = subject.start();
      await Future<void>.delayed(Duration.zero);
      expect(broker.connectCalls, 1);
      await subject.retire();
      broker.connectGate!.complete();
      await start;

      expect(subject.status, ManagedTabletMqttStatus.retired);
      expect(broker.disconnectCalls, 2);
      expect(broker.subscriptions, isEmpty);
      expect(broker.publications, isEmpty);
    },
  );

  test(
    'overlapping reconnect waits for stale connect cleanup before broker reuse',
    () async {
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      final broker = _Broker()..connectGates.addAll([firstGate, secondGate]);
      final subject = _runtime(
        broker: broker,
        store: MemoryManagedMqttStateStore(),
        executor: _Executor(),
        authority: () async => pairing(),
      );

      final first = subject.start();
      await Future<void>.delayed(Duration.zero);
      expect(broker.connectCalls, 1);

      final second = subject.reconnect();
      await Future<void>.delayed(Duration.zero);
      expect(
        broker.connectCalls,
        1,
        reason: 'the replacement must wait for stale cleanup',
      );

      firstGate.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(broker.disconnectCalls, 1);
      expect(broker.connectCalls, 2);
      expect(broker.publications, isEmpty);

      secondGate.complete();
      await second;
      expect(subject.status, ManagedTabletMqttStatus.connected);
      expect(broker.disconnectCalls, 1);
      expect(broker.subscriptions, ['$_prefix/command']);
      expect(broker.publications, hasLength(6));
    },
  );

  test(
    'retire during delayed state read cannot execute an old command',
    () async {
      final gate = Completer<void>();
      final store = _GatedStore(readGate: gate);
      final broker = _Broker();
      final executor = _Executor();
      final subject = _runtime(
        broker: broker,
        store: store,
        executor: executor,
        authority: () async => pairing(),
      );
      await subject.start();
      final publications = broker.publications.length;

      final delivery = broker.deliver(command());
      await store.readStarted.future;
      await subject.retire();
      gate.complete();
      await delivery;

      expect(subject.status, ManagedTabletMqttStatus.retired);
      expect(executor.calls, isEmpty);
      expect(store.value.sequence, 0);
      expect(broker.publications.length, publications);
    },
  );

  test(
    'reconnect during delayed pending write cannot finish the old command',
    () async {
      final gate = Completer<void>();
      final store = _GatedStore(writeGate: gate);
      final broker = _Broker();
      final executor = _Executor();
      final subject = _runtime(
        broker: broker,
        store: store,
        executor: executor,
        authority: () async => pairing(),
      );
      await subject.start();

      final delivery = broker.deliver(command());
      await store.writeStarted.future;
      await subject.reconnect();
      gate.complete();
      await delivery;

      expect(subject.status, ManagedTabletMqttStatus.connected);
      expect(executor.calls, isEmpty);
      expect(store.value.pending, true);
      expect(
        broker.publications.where((entry) => entry.topic == '$_prefix/ack'),
        isEmpty,
      );
    },
  );

  test(
    'pairing authority is rechecked after pending state persistence',
    () async {
      final gate = Completer<void>();
      final store = _GatedStore(writeGate: gate);
      final broker = _Broker();
      final executor = _Executor();
      var credential = pairing();
      final subject = _runtime(
        broker: broker,
        store: store,
        executor: executor,
        authority: () async => credential,
      );
      await subject.start();

      final delivery = broker.deliver(command());
      await store.writeStarted.future;
      credential = pairing(active: false);
      gate.complete();
      await delivery;

      expect(subject.status, ManagedTabletMqttStatus.revoked);
      expect(executor.calls, isEmpty);
      expect(store.value.pending, true);
      expect(
        broker.publications.where((entry) => entry.topic == '$_prefix/ack'),
        isEmpty,
      );
    },
  );

  test('retire during result persistence leaves recovery pending', () async {
    final gate = Completer<void>();
    final store = _GatedStore(writeGate: gate, gatedWriteNumber: 2);
    final broker = _Broker();
    final executor = _Executor();
    final subject = _runtime(
      broker: broker,
      store: store,
      executor: executor,
      authority: () async => pairing(),
    );
    await subject.start();

    final delivery = broker.deliver(command());
    await store.writeStarted.future;
    await subject.retire();
    gate.complete();
    await delivery;

    expect(subject.status, ManagedTabletMqttStatus.retired);
    expect(executor.calls, ['refreshDashboard']);
    expect(store.value.pending, true);
    expect(store.value.result, isNull);
    expect(
      broker.publications.where((entry) => entry.topic == '$_prefix/ack'),
      isEmpty,
    );
  });

  test('partial connect failure disconnects and fails closed', () async {
    final broker = _Broker()..subscribeFailure = StateError('subscribe_failed');
    final subject = _runtime(
      broker: broker,
      store: MemoryManagedMqttStateStore(),
      executor: _Executor(),
      authority: () async => pairing(),
    );

    await expectLater(subject.start(), throwsStateError);

    expect(subject.status, ManagedTabletMqttStatus.failed);
    expect(broker.connectCalls, 1);
    expect(broker.disconnectCalls, 1);
    expect(broker.publications, isEmpty);
  });

  test(
    'telemetry failure after connect disconnects and fails closed',
    () async {
      final broker = _Broker();
      final subject = _runtime(
        broker: broker,
        store: MemoryManagedMqttStateStore(),
        executor: _Executor(),
        authority: () async => pairing(scopes: const {'read'}),
        telemetryReader: () async => throw StateError('telemetry_failed'),
      );

      await expectLater(subject.start(), throwsStateError);

      expect(subject.status, ManagedTabletMqttStatus.failed);
      expect(broker.connectCalls, 1);
      expect(broker.disconnectCalls, 1);
      expect(broker.publications.map((entry) => entry.topic), [
        '$_prefix/availability',
      ]);
    },
  );

  test('retire during telemetry refresh discards the late snapshot', () async {
    final delayed = Completer<ManagedTabletTelemetry>();
    var reads = 0;
    final broker = _Broker();
    final subject = _runtime(
      broker: broker,
      store: MemoryManagedMqttStateStore(),
      executor: _Executor(),
      authority: () async => pairing(scopes: const {'read'}),
      telemetryReader: () {
        reads += 1;
        return reads == 1 ? Future.value(telemetry) : delayed.future;
      },
    );
    await subject.start();
    final before = broker.publications.length;

    final refresh = subject.refreshTelemetry();
    await Future<void>.delayed(Duration.zero);
    await subject.retire();
    delayed.complete(telemetry);
    await refresh;

    expect(subject.status, ManagedTabletMqttStatus.retired);
    expect(broker.publications.length, before);
  });

  test(
    'broker settings reject credential-bearing URLs and redact the adapter',
    () {
      expect(
        () => LocalMqttBrokerSettings(
          enabled: true,
          host: 'mqtt://$_token@mqtt.home.arpa',
          port: 8883,
          tls: true,
        ),
        throwsArgumentError,
      );
      expect(
        MqttClientLocalBroker().toString(),
        allOf(contains('redacted'), isNot(contains(_token))),
      );
    },
  );
}
