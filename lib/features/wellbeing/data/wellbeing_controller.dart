import 'dart:async';
import 'dart:math';

import '../domain/wellbeing_models.dart';
import 'ha_wellbeing_api.dart';
import 'wellbeing_native_api.dart';
import 'wellbeing_store.dart';

class WellbeingController {
  WellbeingController({
    required this.nativeApi,
    required this.haApi,
    required this.settings,
    required this.accessCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final WellbeingNativeApi nativeApi;
  final HaWellbeingApi? haApi;
  final WellbeingSettings settings;
  final bool Function() accessCurrent;
  final DateTime Function() _now;
  final _changes = StreamController<WellbeingSnapshot>.broadcast(sync: true);
  WellbeingSnapshot _snapshot = WellbeingSnapshot();
  bool _visible = false, _foreground = true, _disposed = false;
  int _epoch = 0;
  WellbeingSnapshot get snapshot => _snapshot;
  Stream<WellbeingSnapshot> get stream => Stream.multi((sink) {
    sink.add(_snapshot);
    final sub = _changes.stream.listen(
      sink.add,
      onError: sink.addError,
      onDone: sink.close,
    );
    sink.onCancel = sub.cancel;
  });
  bool get _allowed => !_disposed && _visible && _foreground && accessCurrent();
  bool _current(int epoch) => _allowed && epoch == _epoch;
  void _emit(WellbeingSnapshot value) {
    _snapshot = value;
    if (!_disposed) _changes.add(value);
  }

  void setVisible(bool value) {
    if (_visible == value) return;
    _visible = value;
    if (!value) clear();
  }

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (!value) clear();
  }

  void clear() {
    _epoch++;
    if (_disposed) return;
    _emit(WellbeingSnapshot());
    unawaited(_cancel());
  }

  Future<void> _cancel() async {
    try {
      await nativeApi.cancel();
    } catch (_) {
      /* Epoch already invalidated. */
    }
  }

  Future<void> _operation(Future<void> Function(int epoch) operation) async {
    if (!_allowed || _snapshot.busy) return;
    final epoch = _epoch;
    _emit(
      WellbeingSnapshot(
        statuses: _snapshot.statuses,
        haCandidates: _snapshot.haCandidates,
        busy: true,
      ),
    );
    try {
      await operation(epoch);
    } catch (error) {
      if (_current(epoch)) {
        _emit(
          WellbeingSnapshot(
            statuses: _snapshot.statuses,
            failure: error is WellbeingException
                ? error.failure
                : WellbeingFailure.readFailed,
          ),
        );
      }
    } finally {
      if (_current(epoch) && _snapshot.busy) {
        _emit(
          WellbeingSnapshot(
            statuses: _snapshot.statuses,
            results: _snapshot.results,
            haCandidates: _snapshot.haCandidates,
          ),
        );
      }
    }
  }

  Future<void> probe() => _operation((epoch) async {
    final native = await nativeApi.probe();
    if (!_current(epoch)) return;
    _emit(
      WellbeingSnapshot(
        statuses: {
          for (final source in WellbeingSource.values)
            source: source == native.source
                ? native
                : WellbeingProviderStatus(
                    source: source,
                    checkedAt: _now(),
                    availability: switch (source) {
                      WellbeingSource.homeAssistant =>
                        haApi == null
                            ? WellbeingAvailability.notConfigured
                            : WellbeingAvailability.available,
                      WellbeingSource.huaweiHealth =>
                        WellbeingAvailability.providerRegistrationRequired,
                      _ => WellbeingAvailability.unsupportedPlatform,
                    },
                  ),
        },
        haCandidates: _snapshot.haCandidates,
      ),
    );
  });

  Future<void> loadHaCandidates() => _operation((epoch) async {
    final api = haApi;
    if (api == null) {
      throw const WellbeingException(WellbeingFailure.unavailable);
    }
    final candidates = await api.candidates(isCurrent: () => _current(epoch));
    if (!_current(epoch)) return;
    _emit(
      WellbeingSnapshot(statuses: _snapshot.statuses, haCandidates: candidates),
    );
  });

  HaWellbeingBinding bindCandidate(
    HaWellbeingCandidate candidate,
    WellbeingMetric metric,
    String profileLabel,
  ) {
    if (!_allowed ||
        _snapshot.busy ||
        !_snapshot.haCandidates.contains(candidate) ||
        haApi?.accountFingerprint != candidate.accountFingerprint ||
        !candidate.compatibleMetrics.contains(metric) ||
        !validWellbeingLabel(profileLabel)) {
      throw const WellbeingException(WellbeingFailure.sourceChanged);
    }
    final random = Random.secure();
    return HaWellbeingBinding(
      id: List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
      accountFingerprint: candidate.accountFingerprint,
      entityId: candidate.entityId,
      metric: metric,
      profileLabel: profileLabel.trim(),
    );
  }

  Future<void> requestNativePermissions(Set<WellbeingMetric> metrics) =>
      _operation((epoch) async {
        if (!settings.enabled ||
            metrics.isEmpty ||
            !metrics.every(settings.nativeMetrics.contains)) {
          throw const WellbeingException(WellbeingFailure.locked);
        }
        final status = await nativeApi.requestReadPermissions(metrics);
        if (!_current(epoch)) return;
        // Never start a query when the permission sheet returns.
        _emit(
          WellbeingSnapshot(
            statuses: {..._snapshot.statuses, status.source: status},
          ),
        );
      });

  Future<void> refresh({int days = 30}) => _operation((epoch) async {
    if (!settings.enabled) {
      throw const WellbeingException(WellbeingFailure.locked);
    }
    if (days < 1 || days > 30) {
      throw const WellbeingException(WellbeingFailure.invalidData);
    }
    final results = <WellbeingReadResult>[];
    final statuses = Map<WellbeingSource, WellbeingProviderStatus>.of(
      _snapshot.statuses,
    );
    if (settings.bindings.isNotEmpty) {
      final api = haApi;
      if (api == null) {
        for (final binding in settings.bindings) {
          results.add(
            WellbeingReadResult(
              source: WellbeingSource.homeAssistant,
              metric: binding.metric,
              state: WellbeingReadState.failed,
              failure: WellbeingFailure.unavailable,
            ),
          );
        }
      } else {
        results.addAll(
          await api.read(settings.bindings, isCurrent: () => _current(epoch)),
        );
        if (!_current(epoch)) return;
      }
    }
    if (settings.nativeMetrics.isNotEmpty) {
      var pendingMetrics = settings.nativeMetrics;
      try {
        final status = await nativeApi.probe();
        if (!_current(epoch)) return;
        statuses[status.source] = status;
        final granted = settings.nativeMetrics
            .where(
              (metric) =>
                  status.availability == WellbeingAvailability.available &&
                  status.permissions[metric] == WellbeingPermission.granted,
            )
            .toSet();
        for (final metric in settings.nativeMetrics.difference(granted)) {
          results.add(
            WellbeingReadResult(
              source: status.source,
              metric: metric,
              state: WellbeingReadState.failed,
              failure: status.availability == WellbeingAvailability.available
                  ? WellbeingFailure.permission
                  : WellbeingFailure.unavailable,
            ),
          );
        }
        pendingMetrics = granted;
        if (granted.isNotEmpty) {
          final end = _now();
          results.addAll(
            await nativeApi.read(
              metrics: granted,
              start: end.subtract(Duration(days: days)),
              end: end,
              profileLabel: settings.profileLabel,
            ),
          );
          if (!_current(epoch)) return;
        }
      } catch (error) {
        if (!_current(epoch)) return;
        for (final metric in pendingMetrics) {
          results.add(
            WellbeingReadResult(
              source: nativeApi.source,
              metric: metric,
              state: WellbeingReadState.failed,
              failure: error is WellbeingException
                  ? error.failure
                  : WellbeingFailure.readFailed,
            ),
          );
        }
      }
    }
    if (_current(epoch)) {
      _emit(WellbeingSnapshot(statuses: statuses, results: results));
    }
  });

  void dispose() {
    if (_disposed) return;
    clear();
    _disposed = true;
    _snapshot = WellbeingSnapshot();
    unawaited(_changes.close());
  }
}
