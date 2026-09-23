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
    this.logger,
  });

  final ManagedTabletCredentialStore store;
  final ManagedTabletCoreAuthority authority;
  final ManagedTabletSourcePort source;
  final LocalMqttBroker broker;
  final LocalMqttBrokerSettings settings;
  final ManagedMqttStateStore stateStore;
  final DateTime Function() now;
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
    await store.clearIfCurrent(binding, pairingId);
  }

  Future<void> _schedule(int generation, {bool start = true}) {
    // Detach and retire immediately. A previous start may be waiting on Core,
    // the broker, or telemetry; its callbacks already see the new generation.
    final retirement = _retireCurrent();
    final next = _operations.then((_) async {
      await retirement;
      if (start && _current(generation) && _foreground && settings.enabled) {
        await _start(generation);
      }
    });
    _operations = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  Future<void> _start(int generation) async {
    final binding = _binding;
    if (binding == null || !_current(generation)) return;
    ManagedTabletEnrollment? enrollment;
    try {
      enrollment = await store.read();
      if (!_current(generation) || enrollment?.binding != binding) return;
      final lease = await source.bind(enrollment!.pairingId);
      if (!_current(generation) || lease == null) {
        await source.retire();
        return;
      }
      final runtime = ManagedTabletMqttRuntime(
        broker: broker,
        settings: settings,
        authority: () => _credential(generation, binding, enrollment!),
        telemetry: lease.readTelemetry,
        executor: lease.commandExecutor,
        stateStore: stateStore,
        authorizeEgress: (candidate) =>
            _authorizeEgress(generation, binding, enrollment!, candidate),
        now: now,
        logger: logger,
      );
      _runtime = runtime;
      await runtime.start();
      if (!_current(generation) || !identical(_runtime, runtime)) {
        await runtime.retire();
      }
    } on ManagedTabletRevoked {
      if (enrollment != null) {
        await store.clearIfCurrent(binding, enrollment.pairingId);
      }
      if (_current(generation)) await _retireCurrent();
    } catch (_) {
      if (_current(generation)) await _retireCurrent();
    }
  }

  Future<ManagedTabletPairingCredential> _credential(
    int generation,
    ManagedTabletBinding binding,
    ManagedTabletEnrollment enrollment,
  ) async {
    _assertCurrent(generation, binding);
    await authority.verify(binding, enrollment);
    _assertCurrent(generation, binding);
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
  ) async {
    _assertCurrent(generation, binding);
    if (!identical(candidate, settings) ||
        !candidate.enabled ||
        !candidate.tls) {
      throw StateError('mqtt_egress_denied');
    }
    // Do not rely on the authority result read before this callback. Recheck
    // Core after the runtime has selected the exact broker and before connect.
    await authority.verify(binding, enrollment);
    _assertCurrent(generation, binding);
  }

  void _assertCurrent(int generation, ManagedTabletBinding binding) {
    if (!_current(generation) || _binding != binding || !_foreground) {
      throw StateError('managed_tablet_runtime_retired');
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> _retireCurrent() async {
    final runtime = _runtime;
    _runtime = null;
    await Future.wait<void>([
      if (runtime != null) runtime.retire(),
      source.retire(),
    ]);
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
