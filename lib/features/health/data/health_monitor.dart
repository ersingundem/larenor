import 'dart:async';

import '../../../shared/network/transport_observation.dart';
import 'health_configuration.dart';
import 'integration_health.dart';

/// A provider/client binds one generation per configuration. Late responses
/// from replaced credentials cannot mark the new connection healthy.
class HealthMonitor {
  HealthMonitor({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _states = <IntegrationId, IntegrationHealth>{};
  final _generations = <IntegrationId, int>{};
  final _configurationIdentities = <IntegrationId, Object?>{};
  static const _unspecifiedConfiguration = Object();
  final _changes =
      StreamController<Map<IntegrationId, IntegrationHealth>>.broadcast();
  final _configurationChanges = StreamController<IntegrationId>.broadcast(
    sync: true,
  );
  bool _disposed = false;

  Map<IntegrationId, IntegrationHealth> get snapshot =>
      Map.unmodifiable(_states);
  IntegrationHealth read(IntegrationId id) =>
      _states[id] ?? const IntegrationHealth();
  Stream<IntegrationId> get configurationChanges =>
      _configurationChanges.stream;

  Stream<Map<IntegrationId, IntegrationHealth>> get changes => Stream.multi((
    sink,
  ) {
    final subscription = _changes.stream.listen(sink.add, onDone: sink.close);
    sink.add(snapshot);
    sink.onCancel = subscription.cancel;
  }, isBroadcast: true);

  HealthSession bind(
    IntegrationId id, {
    required bool configured,
    Duration readFreshness = const Duration(minutes: 2),
    Duration liveFreshness = const Duration(seconds: 75),
    Object? configurationIdentity = _unspecifiedConfiguration,
  }) {
    if (!identical(configurationIdentity, _unspecifiedConfiguration)) {
      synchronizeConfiguration(id, configurationIdentity);
    }
    final generation = (_generations[id] ?? 0) + 1;
    _generations[id] = generation;
    _states[id] = IntegrationHealth(
      configured: configured,
      readFreshness: readFreshness,
      liveFreshness: liveFreshness,
    );
    _emit();
    return HealthSession._(this, id, generation);
  }

  /// Local configuration evidence only; no values are serialized or emitted.
  /// Re-reading equivalent saved credentials must preserve active sessions.
  void synchronizeConfiguration(IntegrationId id, Object? configuration) {
    if (_disposed) return;
    if (_configurationIdentities.containsKey(id) &&
        sameHealthConfiguration(_configurationIdentities[id], configuration)) {
      return;
    }
    _configurationIdentities[id] = configuration;
    _generations[id] = (_generations[id] ?? 0) + 1;
    _states[id] = IntegrationHealth(configured: configuration != null);
    _configurationChanges.add(id);
    _emit();
  }

  void _update(
    HealthSession session,
    IntegrationHealth Function(IntegrationHealth) update,
  ) {
    if (_disposed ||
        session._closed ||
        _generations[session.id] != session._generation) {
      return;
    }
    final previous = read(session.id);
    if (!previous.configured) return;
    _states[session.id] = update(previous);
    _emit();
  }

  void _emit() {
    if (!_disposed) _changes.add(snapshot);
  }

  void dispose() {
    _disposed = true;
    unawaited(_changes.close());
    unawaited(_configurationChanges.close());
  }
}

class HealthSession {
  HealthSession._(this._monitor, this.id, this._generation);
  final HealthMonitor _monitor;
  final IntegrationId id;
  final int _generation;
  bool _closed = false;

  /// Ignore late work after client disposal while retaining the last evidence
  /// for health screens. A future bind starts a new independent generation.
  void close() => _closed = true;

  void connecting() => _update((state) => state.copyWith(connecting: true));

  void contact() =>
      _update((state) => state.copyWith(lastContact: _monitor._now()));

  /// Call only after parsing/validating the complete data needed by the screen.
  /// HTTP 200 alone is not a successful domain read.
  void readSucceeded({bool synchronizesLiveSnapshot = false}) => _update((
    state,
  ) {
    final now = _monitor._now();
    return state.copyWith(
      lastSuccessfulRead: now,
      lastContact: now,
      connecting: false,
      clearFailure: true,
      liveSnapshotSynchronized: synchronizesLiveSnapshot && state.liveUpdates
          ? true
          : state.liveSnapshotSynchronized,
    );
  });

  void failed(HealthFailure failure) => _update(
    (state) => state.copyWith(
      failure: failure,
      lastFailureAt: _monitor._now(),
      connecting: false,
    ),
  );

  void retrying(int attempt) => _update(
    (state) => state.copyWith(
      retryAttempt: attempt < 0 ? 0 : attempt,
      connecting: false,
    ),
  );

  void liveConnected() => _update(
    (state) => state.copyWith(
      liveUpdates: true,
      liveSnapshotSynchronized: false,
      lastContact: _monitor._now(),
      lastLiveContact: _monitor._now(),
      retryAttempt: 0,
      connecting: false,
      clearFailure: true,
    ),
  );

  void liveContact() => _update(
    (state) => state.liveUpdates
        ? state.copyWith(
            lastContact: _monitor._now(),
            lastLiveContact: _monitor._now(),
          )
        : state,
  );

  void liveDisconnected() => _update(
    (state) => state.copyWith(
      liveUpdates: false,
      liveSnapshotSynchronized: false,
      connecting: false,
    ),
  );

  /// A 401/403 proves the server answered, while distinguishing authentication
  /// from authorization. A 2xx write never refreshes lastSuccessfulRead.
  void observeTransport(TransportObservation event) {
    if (event.kind == TransportObservationKind.failed) {
      failed(
        event.failure == TransportFailure.timeout
            ? HealthFailure.timeout
            : HealthFailure.transport,
      );
      return;
    }
    if (event.kind != TransportObservationKind.response) return;
    final status = event.statusCode;
    _update(
      (state) => state.copyWith(
        lastContact: _monitor._now(),
        connecting: false,
        failure: switch (status) {
          401 => HealthFailure.authentication,
          403 => HealthFailure.permission,
          final int value when value >= 500 => HealthFailure.server,
          _ => null,
        },
        lastFailureAt: status == 401 || status == 403 || (status ?? 0) >= 500
            ? _monitor._now()
            : null,
      ),
    );
  }

  void _update(IntegrationHealth Function(IntegrationHealth) update) =>
      _monitor._update(this, update);
}
