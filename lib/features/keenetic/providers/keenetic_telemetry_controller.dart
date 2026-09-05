// Public constructor parameter names intentionally differ from private fields.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../shared/utils/foreground_poller.dart';
import '../data/keenetic_api_exception.dart';
import '../data/keenetic_client.dart';
import '../data/keenetic_telemetry.dart';

/// One controller aggregates all visible metric demands for one account.
/// Constructing it is inert: the first foreground subscription starts reads.
class KeeneticTelemetryController with WidgetsBindingObserver {
  KeeneticTelemetryController({
    required KeeneticClient? client,
    KeeneticReadFailure? initialIssue,
    DateTime Function()? now,
    Duration Function()? monotonicNow,
    Duration trafficInterval = const Duration(seconds: 5),
    Duration metadataInterval = const Duration(seconds: 30),
  }) : _client = client,
       _now = now ?? DateTime.now,
       _metadataInterval = metadataInterval,
       _trafficInterval = trafficInterval {
    final stopwatch = Stopwatch()..start();
    _tick = monotonicNow ?? (() => stopwatch.elapsed);
    snapshot = KeeneticTelemetrySnapshot(
      accountGeneration: _account,
      connectionIssue: initialIssue,
    );
    _poller = ForegroundPoller(interval: metadataInterval, poll: _read);
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }
  final KeeneticClient? _client;
  final Object _account = Object();
  final DateTime Function() _now;
  final Duration _metadataInterval, _trafficInterval;
  late final Duration Function() _tick;
  late final ForegroundPoller _poller;
  final _sampler = KeeneticTrafficSampler();
  final _demands = <Object, KeeneticMetricRequest>{};
  final _changes = StreamController<KeeneticTelemetrySnapshot>.broadcast();
  final _interfaceFingerprints = <String, (String?, String?)>{};
  late KeeneticTelemetrySnapshot snapshot;
  DateTime? _lastMetadata;
  int _generation = 0;
  int _demandRevision = 0;
  bool _foreground = true, _disposed = false, _blocked = false;

  Stream<KeeneticTelemetrySnapshot> get changes => Stream.multi((sink) {
    final subscription = _changes.stream.listen(sink.add, onDone: sink.close);
    sink.add(snapshot);
    sink.onCancel = subscription.cancel;
  }, isBroadcast: true);

  /// Returns an idempotent disposer. Identical cards share network work.
  void Function() register(KeeneticMetricRequest request) {
    if (_disposed) return () {};
    final token = Object();
    final alreadyRequested = _demands.values.contains(request);
    _demands[token] = request;
    if (!alreadyRequested) _demandRevision++;
    _setInterval();
    if (_demands.length == 1 && !_blocked) {
      _poller.start();
    } else if (!alreadyRequested && !_blocked) {
      _lastMetadata = null;
      _poller.refresh();
    }
    return () {
      if (_disposed || _demands.remove(token) == null) return;
      _setInterval();
      if (_demands.isEmpty) {
        _generation++;
        _poller.stop();
        _client?.cancelPendingReads();
        _sampler.reset();
        _lastMetadata = null;
      }
    };
  }

  void _setInterval() => _poller.interval =
      _demands.values.any(
        (request) => request.kind == KeeneticMetricKind.wanTraffic,
      )
      ? _trafficInterval
      : _metadataInterval;

  /// Explicit user refresh can retry a denied/expired session. Timer polling
  /// stops after authentication/permission failure; there is no login loop.
  void refresh() {
    if (_disposed || _demands.isEmpty || !_foreground) return;
    _blocked = false;
    _lastMetadata = null;
    _poller.start(immediately: false);
    _poller.refresh();
  }

  Future<void> _read() async {
    final client = _client;
    if (_disposed ||
        !_foreground ||
        _blocked ||
        _demands.isEmpty ||
        client == null) {
      return;
    }
    final generation = _generation;
    final demandRevision = _demandRevision;
    bool current() =>
        !_disposed &&
        _foreground &&
        generation == _generation &&
        _demands.isNotEmpty;
    final demand = KeeneticTelemetryDemand(
      kinds: _demands.values.map((request) => request.kind),
      interfaceIds: _demands.values
          .where((request) => request.kind == KeeneticMetricKind.wanTraffic)
          .map((request) => request.interfaceId)
          .whereType<String>(),
    );
    final now = _now();
    final metadata =
        _lastMetadata == null ||
        now.isBefore(_lastMetadata!) ||
        now.difference(_lastMetadata!) >= _metadataInterval;
    _emit(_copy(isRefreshing: true));
    try {
      if (!client.isAuthenticated) await client.login();
      if (!current()) return;
      final result = await client.readTelemetry(
        demand,
        accountGeneration: _account,
        includeMetadata: metadata,
      );
      if (!current()) return;
      if (metadata && demandRevision == _demandRevision) _lastMetadata = _now();
      final inventory = result.interfaces.value;
      if (inventory != null) {
        final next = {
          for (final item in inventory) item.id: (item.type, item.parentId),
        };
        if (_interfaceFingerprints.isNotEmpty &&
            (next.length != _interfaceFingerprints.length ||
                next.entries.any(
                  (entry) => _interfaceFingerprints[entry.key] != entry.value,
                ))) {
          _sampler.reset();
        }
        _interfaceFingerprints
          ..clear()
          ..addAll(next);
      }
      KeeneticReading<T> merge<T>(
        KeeneticReading<T> next,
        KeeneticReading<T> old,
      ) => next.value == null && next.issue == null ? old : next.retaining(old);
      final traffic = <String, KeeneticReading<KeeneticTrafficSample>>{};
      for (final id in demand.interfaceIds) {
        final next = result.traffic[id];
        if (next == null) continue;
        final sample = next.value;
        traffic[id] = sample == null
            ? next.retaining(snapshot.traffic[id] ?? const KeeneticReading())
            : KeeneticReading(
                value: _sampler.add(
                  sample,
                  _tick(),
                  uptimeSeconds: result.resources.value?.uptimeSeconds,
                ),
                readAt: next.readAt,
              );
      }
      _emit(
        KeeneticTelemetrySnapshot(
          accountGeneration: _account,
          resources: merge(result.resources, snapshot.resources),
          internet: merge(result.internet, snapshot.internet),
          interfaces: merge(result.interfaces, snapshot.interfaces),
          hosts: merge(result.hosts, snapshot.hosts),
          traffic: traffic,
        ),
      );
      final issues = [
        result.resources.issue,
        result.internet.issue,
        result.interfaces.issue,
        result.hosts.issue,
        ...result.traffic.values.map((r) => r.issue),
      ];
      if (issues.any(
        (issue) =>
            issue == KeeneticReadFailure.authentication ||
            issue == KeeneticReadFailure.permission,
      )) {
        _blocked = true;
        _poller.stop();
      }
    } on KeeneticApiException catch (error) {
      if (!current()) return;
      _sampler.reset();
      _emit(_copy(issue: error.failure));
      if (error.failure == KeeneticReadFailure.authentication ||
          error.failure == KeeneticReadFailure.permission) {
        _blocked = true;
        _poller.stop();
      }
    } catch (_) {
      if (current()) _emit(_copy(issue: KeeneticReadFailure.invalidResponse));
    }
  }

  KeeneticTelemetrySnapshot _copy({
    bool isRefreshing = false,
    bool isPaused = false,
    KeeneticReadFailure? issue,
  }) {
    KeeneticReading<T> stale<T>(KeeneticReading<T> reading) => issue == null
        ? reading
        : KeeneticReading(
            value: reading.value,
            readAt: reading.readAt,
            issue: issue,
          );
    return KeeneticTelemetrySnapshot(
      accountGeneration: _account,
      resources: stale(snapshot.resources),
      internet: stale(snapshot.internet),
      interfaces: stale(snapshot.interfaces),
      hosts: stale(snapshot.hosts),
      traffic: {
        for (final entry in snapshot.traffic.entries)
          entry.key: stale(entry.value),
      },
      isRefreshing: isRefreshing,
      isPaused: isPaused,
      connectionIssue: issue,
    );
  }

  void _emit(KeeneticTelemetrySnapshot value) {
    if (_disposed) return;
    snapshot = value;
    _changes.add(value);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _generation++;
    _sampler.reset();
    _lastMetadata = null;
    if (!_foreground) {
      _client?.cancelPendingReads();
      _emit(_copy(isPaused: true, issue: KeeneticReadFailure.inactive));
    }
    // ForegroundPoller observes the same lifecycle and resumes after this reset.
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _poller.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _client?.dispose();
    _demands.clear();
    _sampler.reset();
    unawaited(_changes.close());
  }
}
