import 'dart:async';

import 'managed_tablet_credential_store.dart';
import 'managed_tablet_mqtt_runtime.dart';
import 'mqtt_local_broker.dart';
import 'native_managed_tablet_source.dart';

/// Owns one managed-tablet MQTT generation for the current foreground Core
/// session. Binding changes invalidate callbacks synchronously, then retire the
/// native lease and broker before a replacement can start.
final class ManagedTabletRuntimeOwner {
  ManagedTabletRuntimeOwner({
    required this.store,
    required this.authority,
    required this.source,
    required this.broker,
    required this.settings,
    required this.stateStore,
    required this.now,
    this.onAuthorityRetired,
    this.logger,
  });

  final ManagedTabletCredentialStore store;
  final ManagedTabletCoreAuthority authority;
  final ManagedTabletSourcePort source;
  final LocalMqttBroker broker;
  LocalMqttBrokerSettings settings;
  final ManagedMqttStateStore stateStore;
  final DateTime Function() now;
  final Future<void> Function(ManagedTabletEnrollment enrollment)?
  onAuthorityRetired;
  final void Function(String event)? logger;

  ManagedTabletBinding? _binding;
  ManagedTabletMqttRuntime? _runtime;
  bool _foreground = true, _disposed = false;
  int _generation = 0;
  Future<void> _operations = Future.value();

  Future<void> updateBinding(ManagedTabletBinding? value) {
    if (_disposed) return Future.value();
    if (_binding == value && _runtime != null) return Future.value();
    _binding = value;
    final generation = ++_generation;
    return _schedule(generation);
  }

  Future<void> setForeground(bool value) {
    if (_disposed || value == _foreground) return Future.value();
    _foreground = value;
    final generation = ++_generation;
    return _schedule(generation);
  }

  Future<void> updateSettings(LocalMqttBrokerSettings value) {
    if (_disposed || settings == value) return Future.value();
    settings = value;
    final generation = ++_generation;
    return _schedule(generation);
  }

  Future<ManagedTabletTelemetry> readRemoteViewTelemetry() {
    final runtime = _runtime;
    if (_disposed || !_foreground || runtime == null) {
      return Future<ManagedTabletTelemetry>.error(
        StateError('remote_view_transport_unavailable'),
      );
    }
    return runtime.readRemoteViewTelemetry();
  }

  Future<void> publishRemoteViewFrame({
    required String requestId,
    required int sequence,
    required DateTime capturedAt,
    required List<int> pngBytes,
  }) {
    final runtime = _runtime;
    if (_disposed || !_foreground || runtime == null) {
      return Future<void>.error(
        StateError('remote_view_transport_unavailable'),
      );
    }
    return runtime.publishRemoteViewFrame(
      requestId: requestId,
      sequence: sequence,
      capturedAt: capturedAt,
      pngBytes: pngBytes,
    );
  }

  Future<void> publishRemoteViewReceipt({
    required String requestId,
    required String status,
    required String reasonCode,
  }) {
    final runtime = _runtime;
    if (_disposed || !_foreground || runtime == null) {
      return Future<void>.error(
        StateError('remote_view_transport_unavailable'),
      );
    }
    return runtime.publishRemoteViewReceipt(
      requestId: requestId,
      receiptStatus: status,
      reasonCode: reasonCode,
    );
  }

  Future<void> enroll(
    ManagedTabletBinding binding,
    ManagedTabletEnrollment enrollment, {
    bool Function()? isCurrent,
  }) async {
    final routeCurrent = isCurrent ?? _alwaysCurrent;
    if (_disposed ||
        !_foreground ||
        _binding != binding ||
        enrollment.binding != binding ||
        !_guardCurrent(routeCurrent)) {
      throw StateError('managed_tablet_enrollment_denied');
    }
    final replaced = await store.read();
    if (_disposed || _binding != binding || !_guardCurrent(routeCurrent)) {
      throw StateError('managed_tablet_enrollment_denied');
    }
    final generation = ++_generation;
    await _schedule(generation, start: false);
    if (replaced != null) await onAuthorityRetired?.call(replaced);
    if (!_enrollmentCurrent(generation, binding, routeCurrent)) {
      throw StateError('managed_tablet_enrollment_denied');
    }
    await store.write(enrollment);
    if (!_enrollmentCurrent(generation, binding, routeCurrent)) {
      await store.clearIfExact(enrollment);
      throw StateError('managed_tablet_enrollment_retired');
    }
    final startGeneration = ++_generation;
    await _schedule(startGeneration, enrollmentGuard: routeCurrent);
    if (!_enrollmentCurrent(startGeneration, binding, routeCurrent)) {
      await _schedule(++_generation, start: false);
      await store.clearIfExact(enrollment);
      throw StateError('managed_tablet_enrollment_retired');
    }
  }

  static bool _alwaysCurrent() => true;

  bool _guardCurrent(bool Function() guard) {
    try {
      return guard();
    } catch (_) {
      return false;
    }
  }

  bool _enrollmentCurrent(
    int generation,
    ManagedTabletBinding binding,
    bool Function() guard,
  ) =>
      _current(generation) &&
      _foreground &&
      _binding == binding &&
      _guardCurrent(guard);

  Future<void> revoke(String pairingId) async {
    final binding = _binding;
    if (_disposed || binding == null) return;
    final enrollment = await store.read();
    if (_disposed ||
        _binding != binding ||
        enrollment?.binding != binding ||
        enrollment?.pairingId != pairingId) {
      return;
    }
    final generation = ++_generation;
    await _schedule(generation, start: false);
    await _clearAuthority(binding, pairingId);
  }

  Future<void> _schedule(
    int generation, {
    bool start = true,
    bool Function()? enrollmentGuard,
  }) {
    // Detach and retire immediately. A previous start may be waiting on Core,
    // the broker, or telemetry; its callbacks already see the new generation.
    final retirement = _retireCurrent();
    final next = _operations.then((_) async {
      await retirement;
      if (start &&
          _current(generation) &&
          _foreground &&
          settings.enabled &&
          (enrollmentGuard == null || _guardCurrent(enrollmentGuard))) {
        await _start(generation, enrollmentGuard);
      }
    });
    _operations = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  Future<void> _start(
    int generation, [
    bool Function()? enrollmentGuard,
  ]) async {
    final binding = _binding;
    if (binding == null || !_current(generation)) return;
    ManagedTabletEnrollment? enrollment;
    try {
      enrollment = await store.read();
      if (!_current(generation) || enrollment?.binding != binding) return;
      final lease = await source.bind(enrollment!.pairingId);
      if (!_runtimeCurrent(generation, enrollmentGuard) || lease == null) {
        await source.retire();
        return;
      }
      final runtime = ManagedTabletMqttRuntime(
        broker: broker,
        settings: settings,
        authority: () =>
            _credential(generation, binding, enrollment!, enrollmentGuard),
        telemetry: lease.readTelemetry,
        executor: lease.commandExecutor,
        stateStore: stateStore,
        authorizeEgress: (candidate) => _authorizeEgress(
          generation,
          binding,
          enrollment!,
          candidate,
          enrollmentGuard,
        ),
        now: now,
        onRevoked: () async {
          try {
            await _clearAuthority(binding, enrollment!.pairingId);
          } finally {
            if (_current(generation)) await _retireCurrent();
          }
        },
        logger: logger,
      );
      _runtime = runtime;
      await runtime.start();
      if (!_runtimeCurrent(generation, enrollmentGuard) ||
          !identical(_runtime, runtime)) {
        await runtime.retire();
      }
    } on ManagedTabletRevoked {
      try {
        if (enrollment != null) {
          await _clearAuthority(binding, enrollment.pairingId);
        }
      } finally {
        if (_current(generation)) await _retireCurrent();
      }
    } catch (_) {
      if (_current(generation)) await _retireCurrent();
    }
  }

  Future<ManagedTabletPairingCredential> _credential(
    int generation,
    ManagedTabletBinding binding,
    ManagedTabletEnrollment enrollment,
    bool Function()? enrollmentGuard,
  ) async {
    _assertCurrent(generation, binding, enrollmentGuard);
    await authority.verify(binding, enrollment);
    _assertCurrent(generation, binding, enrollmentGuard);
    final credential = enrollment.credential;
    if (!credential.expiresAt.isAfter(now().toUtc())) {
      throw const ManagedTabletRevoked();
    }
    return credential;
  }

  Future<void> _authorizeEgress(
    int generation,
    ManagedTabletBinding binding,
    ManagedTabletEnrollment enrollment,
    LocalMqttBrokerSettings candidate,
    bool Function()? enrollmentGuard,
  ) async {
    _assertCurrent(generation, binding, enrollmentGuard);
    if (!identical(candidate, settings) ||
        !candidate.enabled ||
        !candidate.tls) {
      throw StateError('mqtt_egress_denied');
    }
    // Do not rely on the authority result read before this callback. Recheck
    // Core after the runtime has selected the exact broker and before connect.
    await authority.verify(binding, enrollment);
    _assertCurrent(generation, binding, enrollmentGuard);
  }

  void _assertCurrent(
    int generation,
    ManagedTabletBinding binding,
    bool Function()? enrollmentGuard,
  ) {
    if (!_runtimeCurrent(generation, enrollmentGuard) || _binding != binding) {
      throw StateError('managed_tablet_runtime_retired');
    }
  }

  bool _runtimeCurrent(int generation, bool Function()? enrollmentGuard) =>
      _current(generation) &&
      _foreground &&
      (enrollmentGuard == null || _guardCurrent(enrollmentGuard));

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> _retireCurrent() async {
    final runtime = _runtime;
    _runtime = null;
    await Future.wait<void>([
      if (runtime != null) runtime.retire(),
      source.retire(),
    ]);
  }

  Future<void> _clearAuthority(
    ManagedTabletBinding binding,
    String pairingId,
  ) async {
    ManagedTabletEnrollment? retired;
    try {
      final candidate = await store.read();
      if (candidate?.binding == binding && candidate?.pairingId == pairingId) {
        retired = candidate;
      }
    } catch (_) {
      // The credential clear below remains authoritative. Without an exact
      // record, this callback must not clear another profile source.
    }
    try {
      await store.clearIfCurrent(binding, pairingId);
    } finally {
      if (retired != null) await onAuthorityRetired?.call(retired);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _binding = null;
    _generation++;
    final retirement = _retireCurrent();
    await _operations;
    await retirement;
  }
}
