import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'managed_tablet_mqtt_runtime.dart';

enum NativeManagedTabletSourceStatus {
  idle,
  disabled,
  unsupported,
  starting,
  active,
  retired,
  failed,
}

final class NativeManagedTabletSourceConfig {
  const NativeManagedTabletSourceConfig({this.enabled = false});

  /// Native collection is opt-in. Constructing this port never starts it.
  final bool enabled;
}

/// Session-bound Android telemetry for the K07 MQTT runtime.
///
/// The wire contract has no arbitrary metadata field, so native code cannot
/// return an SSID, URL, credential, device identifier, or log payload. Binding
/// a new scope retires the previous lease before Android is contacted.
abstract interface class ManagedTabletSourcePort {
  Future<NativeManagedTabletSourceLease?> bind(String scope);
  Future<void> setForeground(bool value);
  Future<void> retire();
}

final class NativeManagedTabletSource implements ManagedTabletSourcePort {
  NativeManagedTabletSource({
    this.config = const NativeManagedTabletSourceConfig(),
    MethodChannel? channel,
    bool? isAndroid,
    String Function()? sessionId,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _isAndroid =
           isAndroid ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
       _sessionId = sessionId ?? _secureSessionId;

  static const channelName =
      'com.ersingundem.larenor/kiosk_remote_tablet_source';

  final NativeManagedTabletSourceConfig config;
  final MethodChannel _channel;
  final bool _isAndroid;
  final String Function() _sessionId;

  NativeManagedTabletSourceStatus status = NativeManagedTabletSourceStatus.idle;
  int _generation = 0;
  _NativeManagedTabletSourceLease? _current;
  String? _pendingSessionId;

  @override
  Future<NativeManagedTabletSourceLease?> bind(String scope) async {
    _validateScope(scope);
    await _retireCurrent();
    if (!_isAndroid) {
      status = NativeManagedTabletSourceStatus.unsupported;
      return null;
    }
    if (!config.enabled) {
      status = NativeManagedTabletSourceStatus.disabled;
      return null;
    }
    final generation = ++_generation;
    final id = _sessionId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
      status = NativeManagedTabletSourceStatus.failed;
      throw StateError('invalid_native_tablet_session');
    }
    status = NativeManagedTabletSourceStatus.starting;
    _pendingSessionId = id;
    try {
      final response = await _channel.invokeMethod<Object?>('start', {
        'schemaVersion': 1,
        'enabled': true,
        'sessionId': id,
        'scope': scope,
      });
      if (generation != _generation ||
          response is! Map ||
          response.length != 1 ||
          response['status'] != 'active') {
        await _stopSession(id);
        throw StateError('native_tablet_source_not_started');
      }
      _pendingSessionId = null;
      final lease = _NativeManagedTabletSourceLease(
        owner: this,
        sessionId: id,
        generation: generation,
      );
      _current = lease;
      status = NativeManagedTabletSourceStatus.active;
      return lease;
    } catch (_) {
      if (_pendingSessionId == id) _pendingSessionId = null;
      if (generation == _generation) {
        status = NativeManagedTabletSourceStatus.failed;
      }
      rethrow;
    }
  }

  @override
  Future<void> setForeground(bool value) async {
    if (!value) await _retireCurrent();
  }

  @override
  Future<void> retire() => _retireCurrent();

  Future<void> _retireCurrent() async {
    final previous = _current;
    final pending = _pendingSessionId;
    _current = null;
    _pendingSessionId = null;
    _generation += 1;
    if (previous == null && pending == null) return;
    previous?._retire();
    status = NativeManagedTabletSourceStatus.retired;
    if (pending != null) await _stopSession(pending);
    if (previous != null) await _stopSession(previous._sessionId);
  }

  Future<void> _stopSession(String sessionId) async {
    try {
      await _channel.invokeMethod<void>('stop', {'sessionId': sessionId});
    } on MissingPluginException {
      // The generation is already retired locally.
    } on PlatformException {
      // The generation is already retired locally.
    }
  }

  Future<ManagedTabletTelemetry> _read(String sessionId, int generation) async {
    _assertCurrent(sessionId, generation);
    final raw = await _channel.invokeMethod<Object?>('snapshot', {
      'sessionId': sessionId,
    });
    _assertCurrent(sessionId, generation);
    return _parseSnapshot(raw);
  }

  void _assertCurrent(String sessionId, int generation) {
    final current = _current;
    if (current == null ||
        current._sessionId != sessionId ||
        current._generation != generation ||
        current._retired ||
        generation != _generation) {
      throw StateError('native_tablet_source_retired');
    }
  }

  bool _isCurrent(String sessionId, int generation) {
    try {
      _assertCurrent(sessionId, generation);
      return true;
    } on StateError {
      return false;
    }
  }

  static ManagedTabletTelemetry _parseSnapshot(Object? raw) {
    const keys = {
      'schemaVersion',
      'batteryPercent',
      'network',
      'appVersion',
      'appForeground',
      'kioskState',
    };
    if (raw is! Map ||
        raw.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(raw.keys.toSet()).isNotEmpty ||
        raw['schemaVersion'] != 1 ||
        raw['batteryPercent'] is! int ||
        raw['network'] is! String ||
        raw['appVersion'] is! String ||
        raw['appForeground'] is! bool ||
        raw['kioskState'] is! String) {
      throw const FormatException('invalid_native_tablet_snapshot');
    }
    final telemetry = ManagedTabletTelemetry(
      batteryPercent: raw['batteryPercent'] as int,
      network: raw['network'] as String,
      appVersion: raw['appVersion'] as String,
      appForeground: raw['appForeground'] as bool,
      kioskState: raw['kioskState'] as String,
    );
    if (!telemetry.appForeground ||
        !const {
          'none',
          'pinned',
          'locked',
          'unknown',
        }.contains(telemetry.kioskState)) {
      throw const FormatException('invalid_native_tablet_snapshot');
    }
    try {
      telemetry.values();
    } on StateError {
      throw const FormatException('invalid_native_tablet_snapshot');
    }
    return telemetry;
  }

  static void _validateScope(String scope) {
    if (!RegExp(r'^[A-Za-z0-9_.:-]{1,128}$').hasMatch(scope)) {
      throw ArgumentError('invalid_native_tablet_scope');
    }
  }

  static String _secureSessionId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

abstract interface class NativeManagedTabletSourceLease {
  Future<ManagedTabletTelemetry> readTelemetry();
  ManagedTabletCommandExecutor get commandExecutor;
}

final class _NativeManagedTabletSourceLease
    implements NativeManagedTabletSourceLease {
  _NativeManagedTabletSourceLease({
    required NativeManagedTabletSource owner,
    required String sessionId,
    required int generation,
  }) : _owner = owner,
       _sessionId = sessionId,
       _generation = generation,
       commandExecutor = _NativeDisabledCommandExecutor(
         owner,
         sessionId,
         generation,
       );

  final NativeManagedTabletSource _owner;
  final String _sessionId;
  final int _generation;
  bool _retired = false;

  @override
  final ManagedTabletCommandExecutor commandExecutor;

  @override
  Future<ManagedTabletTelemetry> readTelemetry() =>
      _owner._read(_sessionId, _generation);

  void _retire() => _retired = true;
}

/// This slice deliberately grants no native command capability.
final class _NativeDisabledCommandExecutor
    implements ManagedTabletCommandExecutor {
  const _NativeDisabledCommandExecutor(
    this._owner,
    this._sessionId,
    this._generation,
  );

  final NativeManagedTabletSource _owner;
  final String _sessionId;
  final int _generation;

  @override
  Future<ManagedTabletCommandResult> execute(String kind) async =>
      _owner._isCurrent(_sessionId, _generation)
      ? ManagedTabletCommandResult.unsupported
      : ManagedTabletCommandResult.denied;
}
