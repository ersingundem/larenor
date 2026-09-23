import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mqtt_local_broker.dart';

enum ManagedTabletMqttStatus {
  idle,
  disabled,
  connecting,
  connected,
  disconnected,
  revoked,
  retired,
  failed,
}

enum ManagedTabletCommandResult { succeeded, denied, failed, unsupported }

abstract interface class ManagedTabletCommandExecutor {
  Future<ManagedTabletCommandResult> execute(String kind);
}

final class ManagedTabletPairingCredential {
  ManagedTabletPairingCredential({
    required this.pairingId,
    required this.deviceId,
    required this.revision,
    required Set<String> scopes,
    required this.expiresAt,
    required this.active,
    required String token,
    required this.clientId,
    required this.topicPrefix,
  }) : scopes = Set.unmodifiable(scopes),
       _token = token {
    final id = RegExp(r'^[0-9a-f]{32}$');
    if (!id.hasMatch(pairingId) ||
        !id.hasMatch(deviceId) ||
        revision < 1 ||
        scopes.isEmpty ||
        !const {'read', 'control', 'admin'}.containsAll(scopes) ||
        token.length != 43 ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token) ||
        clientId != 'larenor-$pairingId' ||
        topicPrefix != 'larenor/$pairingId') {
      throw ArgumentError('invalid_pairing_credential');
    }
  }

  final String pairingId, deviceId, clientId, topicPrefix;
  final int revision;
  final Set<String> scopes;
  final DateTime expiresAt;
  final bool active;
  final String _token;

  bool allows(String scope) =>
      scopes.contains(scope) || scopes.contains('admin');

  T _useToken<T>(T Function(String token) operation) => operation(_token);

  Map<String, Object> get publicMetadata => {
    'pairingId': pairingId,
    'deviceId': deviceId,
    'revision': revision,
    'scopes': scopes.toList()..sort(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'active': active,
    'clientId': clientId,
    'topicPrefix': topicPrefix,
  };

  @override
  String toString() => 'ManagedTabletPairingCredential($publicMetadata)';
}

final class ManagedTabletTelemetry {
  const ManagedTabletTelemetry({
    required this.batteryPercent,
    required this.network,
    required this.appVersion,
    required this.appForeground,
    required this.kioskState,
  });

  final int batteryPercent;
  final bool appForeground;
  final String network, appVersion, kioskState;

  Map<String, Object> values() {
    if (batteryPercent < 0 ||
        batteryPercent > 100 ||
        !const {
          'offline',
          'wifi',
          'ethernet',
          'cellular',
          'other',
        }.contains(network) ||
        appVersion.isEmpty ||
        appVersion.length > 64 ||
        kioskState.isEmpty ||
        kioskState.length > 64) {
      throw StateError('invalid_tablet_telemetry');
    }
    return {
      'battery': batteryPercent,
      'network': network,
      'app_version': appVersion,
      'app_foreground': appForeground,
      'kiosk_state': kioskState,
    };
  }
}

final class ManagedMqttCommandState {
  const ManagedMqttCommandState({
    required this.sequence,
    required this.requestId,
    required this.digest,
    required this.pending,
    required this.result,
    required this.error,
    required this.acceptedAtMs,
  });

  const ManagedMqttCommandState.empty()
    : sequence = 0,
      requestId = null,
      digest = null,
      pending = false,
      result = null,
      error = null,
      acceptedAtMs = const [];

  final int sequence;
  final String? requestId, digest, result, error;
  final bool pending;
  final List<int> acceptedAtMs;

  Map<String, Object?> toJson() => {
    'version': 1,
    'sequence': sequence,
    'requestId': requestId,
    'digest': digest,
    'pending': pending,
    'result': result,
    'error': error,
    'acceptedAtMs': acceptedAtMs,
  };

  static ManagedMqttCommandState fromJson(Object? raw) {
    const keys = {
      'version',
      'sequence',
      'requestId',
      'digest',
      'pending',
      'result',
      'error',
      'acceptedAtMs',
    };
    if (raw is! Map<String, dynamic> ||
        raw.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(raw.keys.toSet()).isNotEmpty ||
        raw['version'] != 1 ||
        raw['sequence'] is! int ||
        (raw['sequence'] as int) < 0 ||
        raw['pending'] is! bool ||
        raw['acceptedAtMs'] is! List) {
      throw const FormatException('invalid_mqtt_state');
    }
    final requestId = raw['requestId'];
    final digest = raw['digest'];
    final result = raw['result'];
    final error = raw['error'];
    final times = (raw['acceptedAtMs'] as List).whereType<int>().toList();
    if (times.length != (raw['acceptedAtMs'] as List).length ||
        times.length > 30 ||
        times.any((value) => value < 0) ||
        times.indexed.any(
          (entry) => entry.$1 > 0 && times[entry.$1 - 1] > entry.$2,
        ) ||
        (requestId != null && requestId is! String) ||
        (digest != null && digest is! String) ||
        (result != null && result is! String) ||
        (error != null && error is! String)) {
      throw const FormatException('invalid_mqtt_state');
    }
    return ManagedMqttCommandState(
      sequence: raw['sequence'] as int,
      requestId: requestId as String?,
      digest: digest as String?,
      pending: raw['pending'] as bool,
      result: result as String?,
      error: error as String?,
      acceptedAtMs: List.unmodifiable(times),
    );
  }
}

abstract interface class ManagedMqttStateStore {
  Future<ManagedMqttCommandState> read(String pairingId);
  Future<void> write(String pairingId, ManagedMqttCommandState state);
}

final class MemoryManagedMqttStateStore implements ManagedMqttStateStore {
  final _values = <String, ManagedMqttCommandState>{};

  @override
  Future<ManagedMqttCommandState> read(String pairingId) async =>
      _values[pairingId] ?? const ManagedMqttCommandState.empty();

  @override
  Future<void> write(String pairingId, ManagedMqttCommandState state) async {
    _values[pairingId] = state;
  }
}

final class SharedPreferencesManagedMqttStateStore
    implements ManagedMqttStateStore {
  SharedPreferencesManagedMqttStateStore({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  static const keyPrefix = 'kiosk_remote_mqtt_state_v1_';
  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<ManagedMqttCommandState> read(String pairingId) async {
    final raw = (await _preferences()).getString('$keyPrefix$pairingId');
    if (raw == null) return const ManagedMqttCommandState.empty();
    return ManagedMqttCommandState.fromJson(jsonDecode(raw));
  }

  @override
  Future<void> write(String pairingId, ManagedMqttCommandState state) async {
    if (!await (await _preferences()).setString(
      '$keyPrefix$pairingId',
      jsonEncode(state.toJson()),
    )) {
      throw StateError('mqtt_state_not_persisted');
    }
  }
}

typedef PairingAuthority = Future<ManagedTabletPairingCredential> Function();
typedef TabletTelemetryReader = Future<ManagedTabletTelemetry> Function();
typedef MqttEgressAuthorizer = Future<void> Function(
  LocalMqttBrokerSettings settings,
);

final class _RetiredMqttGeneration implements Exception {
  const _RetiredMqttGeneration();
}

final class ManagedTabletMqttRuntime {
  ManagedTabletMqttRuntime({
    required this.broker,
    required this.settings,
    required this.authority,
    required this.telemetry,
    required this.executor,
    required this.stateStore,
    required this.authorizeEgress,
    required this.now,
    this.logger,
    this.maxCommandsPerMinute = 30,
  }) {
    if (maxCommandsPerMinute < 1 || maxCommandsPerMinute > 30) {
      throw ArgumentError('invalid_mqtt_rate_limit');
    }
  }

  final LocalMqttBroker broker;
  final LocalMqttBrokerSettings settings;
  final PairingAuthority authority;
  final TabletTelemetryReader telemetry;
  final ManagedTabletCommandExecutor executor;
  final ManagedMqttStateStore stateStore;
  final MqttEgressAuthorizer authorizeEgress;
  final DateTime Function() now;
  final void Function(String event)? logger;
  final int maxCommandsPerMinute;

  ManagedTabletMqttStatus status = ManagedTabletMqttStatus.idle;
  ManagedTabletPairingCredential? _pairing;
  Future<void> _messages = Future.value();
  Future<void> _connections = Future.value();
  int _generation = 0;

  Future<void> start() async {
    if (!settings.enabled) {
      _generation += 1;
      status = ManagedTabletMqttStatus.disabled;
      _log('mqtt_runtime_disabled');
      return;
    }
    final generation = ++_generation;
    await _scheduleConnect(generation);
  }

  Future<void> _scheduleConnect(int generation) {
    final next = _connections.then((_) => _connect(generation));
    _connections = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> _connect(int generation) async {
    if (!_isGeneration(generation)) return;
    status = ManagedTabletMqttStatus.connecting;
    var connectStarted = false;
    try {
      final current = await authority();
      _assertGeneration(generation);
      _assertUsable(current, 'read');
      final bound = _pairing;
      if (bound != null &&
          (bound.pairingId != current.pairingId ||
              bound.deviceId != current.deviceId ||
              bound.revision != current.revision)) {
        await _revoke();
        return;
      }
      _pairing = current;
      await authorizeEgress(settings);
      _assertGeneration(generation);
      connectStarted = true;
      await current._useToken(
        (token) => broker.connect(
          settings: settings,
          clientId: current.clientId,
          username: current.pairingId,
          password: token,
          onMessage: (message) => _enqueue(message, generation),
          onDisconnected: () => _disconnected(generation),
        ),
      );
      _assertGeneration(generation);
      if (current.allows('control')) {
        await broker.subscribe('${current.topicPrefix}/command');
        _assertGeneration(generation);
      }
      await _publishAvailability(current, 'online', generation);
      await _publishTelemetry(current, generation);
      _assertGeneration(generation);
      status = ManagedTabletMqttStatus.connected;
      _log('mqtt_runtime_connected');
    } on _RetiredMqttGeneration {
      if (connectStarted) await _disconnectQuietly();
    } on StateError catch (error) {
      if (connectStarted) await _disconnectQuietly();
      if (!_isGeneration(generation)) return;
      if (error.message == 'pairing_revoked') {
        await _revoke();
        return;
      }
      status = ManagedTabletMqttStatus.failed;
      _log('mqtt_runtime_connect_failed');
      rethrow;
    } catch (_) {
      if (connectStarted) await _disconnectQuietly();
      if (!_isGeneration(generation)) return;
      if (status != ManagedTabletMqttStatus.revoked) {
        status = ManagedTabletMqttStatus.failed;
        _log('mqtt_runtime_connect_failed');
      }
      rethrow;
    }
  }

  Future<void> reconnect() async {
    if (status == ManagedTabletMqttStatus.disabled ||
        status == ManagedTabletMqttStatus.revoked ||
        status == ManagedTabletMqttStatus.retired) {
      return;
    }
    final generation = ++_generation;
    await _scheduleConnect(generation);
  }

  Future<void> refreshTelemetry() async {
    final generation = _generation;
    final current = await _current('read', generation);
    if (current == null) return;
    try {
      await _publishTelemetry(current, generation);
    } on _RetiredMqttGeneration {
      return;
    }
  }

  Future<void> retire() async {
    _generation += 1;
    status = ManagedTabletMqttStatus.retired;
    _pairing = null;
    await broker.disconnect();
    _log('mqtt_runtime_retired');
  }

  void _disconnected(int generation) {
    if (!_isGeneration(generation)) return;
    if (status == ManagedTabletMqttStatus.connected ||
        status == ManagedTabletMqttStatus.connecting) {
      status = ManagedTabletMqttStatus.disconnected;
      _log('mqtt_runtime_disconnected');
    }
  }

  Future<void> _enqueue(BrokerMessage message, int generation) {
    final next = _messages.then((_) => _handle(message, generation));
    _messages = next.catchError((_) {
      _log('mqtt_command_failed_closed');
    });
    return next;
  }

  Future<void> _handle(BrokerMessage message, int generation) async {
    final current = await _current('control', generation);
    if (current == null) return;
    if (message.topic != '${current.topicPrefix}/command' ||
        message.retained ||
        message.payload.isEmpty ||
        message.payload.length > 4096) {
      await _publishError(current, 0, null, 'mqtt_retained_command_denied');
      return;
    }
    Map<String, dynamic> body;
    try {
      final raw = jsonDecode(
        utf8.decode(message.payload, allowMalformed: false),
      );
      if (raw is! Map<String, dynamic>) throw const FormatException();
      body = raw;
    } catch (_) {
      await _publishError(current, 0, null, 'invalid_mqtt_command');
      return;
    }
    final parsed = _parse(body);
    if (parsed == null) {
      await _publishError(current, 0, null, 'invalid_mqtt_command');
      return;
    }
    final (:requestId, :sequence, :kind, :expiresAt) = parsed;
    final currentTime = now().toUtc();
    if (!expiresAt.isAfter(currentTime) ||
        expiresAt.isAfter(currentTime.add(const Duration(minutes: 5)))) {
      await _publishError(current, sequence, requestId, 'mqtt_command_expired');
      return;
    }
    if (kind == 'lockKiosk' && !current.scopes.contains('admin')) {
      await _publishError(current, sequence, requestId, 'pairing_scope_denied');
      return;
    }
    final digest = sha256.convert(message.payload).toString();
    var state = await stateStore.read(current.pairingId);
    if (sequence < state.sequence) {
      await _publishError(current, sequence, requestId, 'mqtt_command_replay');
      return;
    }
    if (sequence == state.sequence && state.sequence != 0) {
      if (state.digest != digest || state.requestId != requestId) {
        await _publishError(
          current,
          sequence,
          requestId,
          'mqtt_command_conflict',
        );
        return;
      }
      if (state.pending) {
        state = ManagedMqttCommandState(
          sequence: state.sequence,
          requestId: state.requestId,
          digest: state.digest,
          pending: false,
          result: ManagedTabletCommandResult.failed.name,
          error: 'execution_unconfirmed',
          acceptedAtMs: state.acceptedAtMs,
        );
        await stateStore.write(current.pairingId, state);
      }
      await _publishState(current, state, replayed: true);
      return;
    }
    final cutoff = currentTime
        .subtract(const Duration(minutes: 1))
        .millisecondsSinceEpoch;
    final recent = state.acceptedAtMs.where((value) => value > cutoff).toList();
    if (recent.length >= maxCommandsPerMinute) {
      await _publishError(current, sequence, requestId, 'rate_limited');
      return;
    }
    recent.add(currentTime.millisecondsSinceEpoch);
    state = ManagedMqttCommandState(
      sequence: sequence,
      requestId: requestId,
      digest: digest,
      pending: true,
      result: null,
      error: null,
      acceptedAtMs: List.unmodifiable(recent),
    );
    await stateStore.write(current.pairingId, state);
    ManagedTabletCommandResult result;
    String? error;
    try {
      result = await executor.execute(kind);
    } catch (_) {
      result = ManagedTabletCommandResult.failed;
      error = 'execution_failed';
    }
    final after = await _current('control', generation);
    if (after == null) return;
    state = ManagedMqttCommandState(
      sequence: sequence,
      requestId: requestId,
      digest: digest,
      pending: false,
      result: result.name,
      error: error,
      acceptedAtMs: state.acceptedAtMs,
    );
    await stateStore.write(current.pairingId, state);
    await _publishState(after, state, replayed: false);
  }

  ({String requestId, int sequence, String kind, DateTime expiresAt})? _parse(
    Map<String, dynamic> body,
  ) {
    if (body.keys.toSet().difference(const {
          'schemaVersion',
          'requestId',
          'sequence',
          'kind',
          'retained',
          'expiresAt',
        }).isNotEmpty ||
        body.length != 6 ||
        body['schemaVersion'] != 1 ||
        body['requestId'] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(body['requestId'] as String) ||
        body['sequence'] is! int ||
        (body['sequence'] as int) < 1 ||
        body['retained'] != false ||
        !const {
          'refreshDashboard',
          'syncProfile',
          'lockKiosk',
        }.contains(body['kind']) ||
        body['expiresAt'] is! num ||
        !(body['expiresAt'] as num).isFinite) {
      return null;
    }
    return (
      requestId: body['requestId'] as String,
      sequence: body['sequence'] as int,
      kind: body['kind'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        ((body['expiresAt'] as num) * 1000).round(),
        isUtc: true,
      ),
    );
  }

  Future<ManagedTabletPairingCredential?> _current(
    String scope,
    int generation,
  ) async {
    if (!_isGeneration(generation)) return null;
    final bound = _pairing;
    if (bound == null) return null;
    try {
      final current = await authority();
      if (!_isGeneration(generation) || _pairing != bound) return null;
      if (current.pairingId != bound.pairingId ||
          current.deviceId != bound.deviceId ||
          current.revision != bound.revision) {
        await _revoke();
        return null;
      }
      _assertUsable(current, scope);
      return current;
    } catch (_) {
      if (!_isGeneration(generation)) return null;
      await _revoke();
      return null;
    }
  }

  void _assertUsable(ManagedTabletPairingCredential value, String scope) {
    if (!value.active || !value.expiresAt.isAfter(now().toUtc())) {
      throw StateError('pairing_revoked');
    }
    if (!value.allows(scope)) throw StateError('pairing_scope_denied');
  }

  Future<void> _revoke() async {
    _generation += 1;
    status = ManagedTabletMqttStatus.revoked;
    _pairing = null;
    await broker.disconnect();
    _log('mqtt_runtime_revoked');
  }

  Future<void> _publishAvailability(
    ManagedTabletPairingCredential current,
    String value,
    int generation,
  ) async {
    _assertGeneration(generation);
    await broker.publish(
      '${current.topicPrefix}/availability',
      utf8.encode(value),
      retained: true,
    );
    _assertGeneration(generation);
  }

  Future<void> _publishTelemetry(
    ManagedTabletPairingCredential current,
    int generation,
  ) async {
    final values = (await telemetry()).values();
    _assertGeneration(generation);
    for (final entry in values.entries) {
      _assertGeneration(generation);
      await broker.publish(
        '${current.topicPrefix}/sensor/${entry.key}/state',
        utf8.encode(
          jsonEncode({
            'schemaVersion': 1,
            'deviceId': current.deviceId,
            'value': entry.value,
          }),
        ),
        retained: true,
      );
      _assertGeneration(generation);
    }
  }

  bool _isGeneration(int generation) => generation == _generation;

  void _assertGeneration(int generation) {
    if (!_isGeneration(generation)) throw const _RetiredMqttGeneration();
  }

  Future<void> _disconnectQuietly() async {
    try {
      await broker.disconnect();
    } catch (_) {
      // Cleanup is best effort; the original failure remains authoritative.
    }
  }

  Future<void> _publishState(
    ManagedTabletPairingCredential current,
    ManagedMqttCommandState state, {
    required bool replayed,
  }) => broker.publish(
    '${current.topicPrefix}/ack',
    utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'requestId': state.requestId,
        'sequence': state.sequence,
        'result': state.result,
        'replayed': replayed,
        if (state.error != null) 'error': state.error,
      }),
    ),
    retained: false,
  );

  Future<void> _publishError(
    ManagedTabletPairingCredential current,
    int sequence,
    String? requestId,
    String error,
  ) => broker.publish(
    '${current.topicPrefix}/ack',
    utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'requestId': requestId,
        'sequence': sequence,
        'result': ManagedTabletCommandResult.denied.name,
        'replayed': false,
        'error': error,
      }),
    ),
    retained: false,
  );

  void _log(String event) => logger?.call(event);
}
