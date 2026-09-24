import 'dart:async';
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
  const NativeManagedTabletSourceConfig({
    this.enabled = false,
    this.nativeCallTimeout = const Duration(seconds: 10),
  });

  /// Native collection is opt-in. Constructing this port never starts it.
  final bool enabled;

  /// One total deadline for each platform call; chunks do not reset it.
  final Duration nativeCallTimeout;
}

abstract interface class ManagedTabletLocalActions {
  Future<void> refreshDashboard({required bool Function() isCurrent});
  Future<void> syncProfile({required bool Function() isCurrent});
}

final class CallbackManagedTabletLocalActions
    implements ManagedTabletLocalActions {
  const CallbackManagedTabletLocalActions({
    required this.onRefreshDashboard,
    this.onSyncProfile,
  });

  final Future<void> Function(bool Function() isCurrent) onRefreshDashboard;
  final Future<void> Function(bool Function() isCurrent)? onSyncProfile;

  @override
  Future<void> refreshDashboard({required bool Function() isCurrent}) =>
      onRefreshDashboard(isCurrent);

  @override
  Future<void> syncProfile({required bool Function() isCurrent}) {
    final callback = onSyncProfile;
    if (callback == null) {
      return Future<void>.error(
        UnsupportedError('managed_tablet_profile_sync_disabled'),
      );
    }
    return callback(isCurrent);
  }
}

final class DisabledManagedTabletLocalActions
    implements ManagedTabletLocalActions {
  const DisabledManagedTabletLocalActions();

  @override
  Future<void> refreshDashboard({required bool Function() isCurrent}) =>
      Future<void>.error(UnsupportedError('managed_tablet_action_disabled'));

  @override
  Future<void> syncProfile({required bool Function() isCurrent}) =>
      Future<void>.error(UnsupportedError('managed_tablet_action_disabled'));
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
    ManagedTabletLocalActions? actions,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _isAndroid =
           isAndroid ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
       _sessionId = sessionId ?? _secureSessionId,
       _actions = actions ?? const DisabledManagedTabletLocalActions() {
    if (config.nativeCallTimeout <= Duration.zero) {
      throw ArgumentError.value(config.nativeCallTimeout, 'nativeCallTimeout');
    }
  }

  static const channelName =
      'com.ersingundem.larenor/kiosk_remote_tablet_source';
  static final Object _retiredNativeCall = Object();

  final NativeManagedTabletSourceConfig config;
  final MethodChannel _channel;
  final bool _isAndroid;
  final String Function() _sessionId;
  final ManagedTabletLocalActions _actions;

  NativeManagedTabletSourceStatus status = NativeManagedTabletSourceStatus.idle;
  int _generation = 0;
  _NativeManagedTabletSourceLease? _current;
  String? _pendingSessionId;
  Completer<void>? _pendingRetirement;

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
    final retirement = Completer<void>();
    _pendingRetirement = retirement;
    try {
      final response = await _awaitNative(
        _channel.invokeMethod<Object?>('start', {
          'schemaVersion': 1,
          'enabled': true,
          'sessionId': id,
          'scope': scope,
        }),
      );
      if (generation != _generation ||
          response is! Map ||
          response.length != 1 ||
          response['status'] != 'active') {
        if (!retirement.isCompleted) retirement.complete();
        await _stopSession(id);
        throw StateError('native_tablet_source_not_started');
      }
      _pendingSessionId = null;
      _pendingRetirement = null;
      final lease = _NativeManagedTabletSourceLease(
        owner: this,
        sessionId: id,
        generation: generation,
        retirement: retirement,
      );
      _current = lease;
      status = NativeManagedTabletSourceStatus.active;
      return lease;
    } catch (_) {
      if (_pendingSessionId == id) _pendingSessionId = null;
      if (identical(_pendingRetirement, retirement)) {
        _pendingRetirement = null;
      }
      if (!retirement.isCompleted) {
        retirement.complete();
        await _stopSession(id);
      }
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
    final pendingRetirement = _pendingRetirement;
    _current = null;
    _pendingSessionId = null;
    _pendingRetirement = null;
    _generation += 1;
    if (previous == null && pending == null) return;
    if (pendingRetirement != null && !pendingRetirement.isCompleted) {
      pendingRetirement.complete();
    }
    previous?._retire();
    status = NativeManagedTabletSourceStatus.retired;
    if (pending != null) await _stopSession(pending);
    if (previous != null) await _stopSession(previous._sessionId);
  }

  Future<void> _stopSession(String sessionId) async {
    try {
      await _channel
          .invokeMethod<void>('stop', {'sessionId': sessionId})
          .timeout(config.nativeCallTimeout);
    } on MissingPluginException {
      // The generation is already retired locally.
    } on PlatformException {
      // The generation is already retired locally.
    } on TimeoutException {
      // The local generation is already retired; native cleanup is bounded.
    }
  }

  Future<T> _awaitNative<T>(
    Future<T> operation, [
    Future<void>? retired,
  ]) async {
    try {
      final result = await Future.any<Object?>([
        operation,
        if (retired != null) retired.then<Object?>((_) => _retiredNativeCall),
      ]).timeout(config.nativeCallTimeout);
      if (identical(result, _retiredNativeCall)) {
        throw StateError('native_tablet_source_retired');
      }
      return result as T;
    } on TimeoutException {
      throw StateError('native_tablet_source_timeout');
    }
  }

  Future<ManagedTabletTelemetry> _read(
    _NativeManagedTabletSourceLease lease,
  ) async {
    _assertCurrent(lease);
    final raw = await _awaitNative(
      _channel.invokeMethod<Object?>('snapshot', {
        'sessionId': lease._sessionId,
      }),
    );
    _assertCurrent(lease);
    return _parseSnapshot(raw);
  }

  Future<ManagedTabletCommandResult> _executeNativeCommand(
    _NativeManagedTabletSourceLease lease,
    String kind,
  ) async {
    _assertCurrent(lease);
    Object? raw;
    try {
      raw = await _awaitNative(
        _channel.invokeMethod<Object?>('command', {
          'sessionId': lease._sessionId,
          'kind': kind,
        }),
        lease._retirement.future,
      );
    } on MissingPluginException {
      return _isCurrent(lease)
          ? ManagedTabletCommandResult.unsupported
          : ManagedTabletCommandResult.denied;
    } on PlatformException catch (error) {
      if (!_isCurrent(lease)) {
        return ManagedTabletCommandResult.denied;
      }
      return error.code == 'denied'
          ? ManagedTabletCommandResult.denied
          : ManagedTabletCommandResult.failed;
    } on StateError {
      return _isCurrent(lease)
          ? ManagedTabletCommandResult.failed
          : ManagedTabletCommandResult.denied;
    }
    if (!_isCurrent(lease)) {
      return ManagedTabletCommandResult.denied;
    }
    if (raw is! Map ||
        raw.length != 1 ||
        raw.keys.single != 'result' ||
        raw['result'] is! String) {
      return ManagedTabletCommandResult.failed;
    }
    return switch (raw['result']) {
      'succeeded' => ManagedTabletCommandResult.succeeded,
      'denied' => ManagedTabletCommandResult.denied,
      'failed' => ManagedTabletCommandResult.failed,
      _ => ManagedTabletCommandResult.failed,
    };
  }

  void _assertCurrent(_NativeManagedTabletSourceLease lease) {
    final current = _current;
    if (!identical(current, lease) ||
        lease._retired ||
        lease._generation != _generation) {
      throw StateError('native_tablet_source_retired');
    }
  }

  bool _isCurrent(_NativeManagedTabletSourceLease lease) {
    try {
      _assertCurrent(lease);
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
    required this._sessionId,
    required this._generation,
    required this._retirement,
  }) : _owner = owner {
    commandExecutor = _NativeManagedTabletCommandExecutor(
      owner,
      this,
      owner._actions,
    );
  }

  final NativeManagedTabletSource _owner;
  final String _sessionId;
  final int _generation;
  final Completer<void> _retirement;
  bool _retired = false;

  @override
  late final ManagedTabletCommandExecutor commandExecutor;

  @override
  Future<ManagedTabletTelemetry> readTelemetry() => _owner._read(this);

  void _retire() {
    _retired = true;
    if (!_retirement.isCompleted) _retirement.complete();
  }
}

final class _NativeManagedTabletCommandExecutor
    implements ManagedTabletCommandExecutor {
  _NativeManagedTabletCommandExecutor(this._owner, this._lease, this._actions);

  final NativeManagedTabletSource _owner;
  final _NativeManagedTabletSourceLease _lease;
  final ManagedTabletLocalActions _actions;
  bool _working = false;

  @override
  Future<ManagedTabletCommandResult> execute(String kind) async {
    bool current() => _owner._isCurrent(_lease);
    if (!current()) return ManagedTabletCommandResult.denied;
    if (kind != 'refreshDashboard' &&
        kind != 'syncProfile' &&
        kind != 'lockKiosk') {
      return ManagedTabletCommandResult.unsupported;
    }
    if (_working) return ManagedTabletCommandResult.denied;
    _working = true;
    final operation = switch (kind) {
      'refreshDashboard' => Future<ManagedTabletCommandResult>.sync(() async {
        await _actions.refreshDashboard(isCurrent: current);
        return ManagedTabletCommandResult.succeeded;
      }),
      'syncProfile' => Future<ManagedTabletCommandResult>.sync(() async {
        await _actions.syncProfile(isCurrent: current);
        return ManagedTabletCommandResult.succeeded;
      }),
      _ => _owner._executeNativeCommand(_lease, kind),
    };
    operation.then<void>(
      (_) => _working = false,
      onError: (_, _) => _working = false,
    );
    try {
      final result = await operation.timeout(configuredTimeout);
      return current() ? result : ManagedTabletCommandResult.denied;
    } on UnsupportedError {
      return current()
          ? ManagedTabletCommandResult.unsupported
          : ManagedTabletCommandResult.denied;
    } catch (_) {
      return current()
          ? ManagedTabletCommandResult.failed
          : ManagedTabletCommandResult.denied;
    }
  }

  Duration get configuredTimeout => _owner.config.nativeCallTimeout;
}
