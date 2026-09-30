import 'package:flutter/foundation.dart';

import '../domain/sound_event_models.dart';

abstract interface class SoundEventApi {
  Future<SoundEventSnapshot> load(
    SoundEventAuthority expected,
    SoundEventFilter filter,
  );
  Future<SoundEventAcknowledgement> acknowledge(
    SoundEventAuthority expected,
    SoundEventSnapshot current,
    SoundEventItem event,
  );
}

abstract interface class SoundEventControlApi implements SoundEventApi {
  Future<SoundEventPolicyReceipt> updatePolicy(
    SoundEventAuthority expected,
    SoundEventSnapshot current, {
    required bool notificationsEnabled,
    required bool barkEnabled,
    required bool noiseEnabled,
    required DateTime? mutedUntil,
  });
  Future<SoundEventFeedbackReceipt> feedback(
    SoundEventAuthority expected,
    SoundEventSnapshot current,
    SoundEventItem event,
    String classification,
  );
}

abstract interface class SoundEventSourceApi implements SoundEventApi {
  Future<SoundEventSnapshot> refreshSource();
}

enum SoundEventViewState { idle, loading, ready, busy, verified, failed, stale }

final class SoundEventController extends ChangeNotifier {
  SoundEventController({
    required this.api,
    required this.authority,
    required this.isCurrent,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SoundEventApi api;
  SoundEventAuthority authority;
  final bool Function() isCurrent;
  final DateTime Function() _clock;
  int _epoch = 0;
  bool _interactive = true, _disposed = false;
  SoundEventViewState state = SoundEventViewState.idle;
  SoundEventSnapshot? snapshot;
  SoundEventFilter filter = const SoundEventFilter();

  bool _current() {
    if (_disposed || !_interactive || !authority.isBounded) return false;
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool _operationCurrent(int operation) => operation == _epoch && _current();
  bool get canAct =>
      _current() &&
      state != SoundEventViewState.loading &&
      state != SoundEventViewState.busy;
  bool get canControl => api is SoundEventControlApi;

  List<SoundEventItem> get visibleEvents => List.unmodifiable(
    (snapshot?.events ?? const <SoundEventItem>[]).where((event) {
      final classMatch = switch (filter.eventClass) {
        SoundEventClassFilter.all => true,
        SoundEventClassFilter.bark => event.className == 'bark',
        SoundEventClassFilter.noise => event.className != 'bark',
      };
      final statusMatch = switch (filter.status) {
        SoundEventStatusFilter.all => true,
        SoundEventStatusFilter.unacknowledged => !event.acknowledged,
        SoundEventStatusFilter.acknowledged => event.acknowledged,
      };
      return classMatch && statusMatch;
    }),
  );

  void _stale() {
    snapshot = null;
    state = SoundEventViewState.stale;
    if (!_disposed) notifyListeners();
  }

  void setInteractive(bool value) {
    if (_disposed || value == _interactive) return;
    _interactive = value;
    if (!value) {
      _epoch++;
      _stale();
    }
  }

  void setFilter(SoundEventFilter value) {
    if (!_current() || filter == value) return;
    filter = value;
    notifyListeners();
  }

  Future<void> load() async {
    if (!_current()) {
      _stale();
      return;
    }
    final operation = ++_epoch;
    snapshot = null;
    state = SoundEventViewState.loading;
    notifyListeners();
    try {
      final response = await api.load(authority, filter);
      if (!_operationCurrent(operation)) return _stale();
      if (!response.coherentFor(authority, _clock().toUtc())) {
        state = SoundEventViewState.failed;
      } else {
        snapshot = response;
        state = SoundEventViewState.ready;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) return _stale();
      state = SoundEventViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> acknowledge(SoundEventItem event) async {
    final before = snapshot;
    if (!canAct ||
        before == null ||
        event.acknowledged ||
        !authority.canAcknowledge ||
        !before.events.any((candidate) => identical(candidate, event))) {
      return;
    }
    final operation = ++_epoch;
    state = SoundEventViewState.busy;
    notifyListeners();
    try {
      final receipt = await api.acknowledge(authority, before, event);
      if (!_operationCurrent(operation)) return _stale();
      if (!receipt.exactFor(authority, before, event)) {
        state = SoundEventViewState.failed;
        notifyListeners();
        return;
      }
      final nextAuthority = authority.withRepositoryRevision(
        receipt.repositoryRevision,
      );
      final readback = await api.load(nextAuthority, filter);
      if (!_operationCurrent(operation)) return _stale();
      final verified = readback.events
          .where((candidate) => candidate.eventId == event.eventId)
          .firstOrNull;
      if (!readback.coherentFor(nextAuthority, _clock().toUtc()) ||
          verified == null ||
          !verified.acknowledged ||
          verified.eventRevision != receipt.eventRevision) {
        snapshot = null;
        state = SoundEventViewState.failed;
      } else {
        authority = nextAuthority;
        snapshot = readback;
        state = SoundEventViewState.verified;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) return _stale();
      snapshot = null;
      state = SoundEventViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> updatePolicy({
    required bool notificationsEnabled,
    required bool barkEnabled,
    required bool noiseEnabled,
    required DateTime? mutedUntil,
  }) async {
    final before = snapshot;
    final normalizedMute = mutedUntil == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            mutedUntil.toUtc().millisecondsSinceEpoch,
            isUtc: true,
          );
    final control = api;
    if (!canAct || before == null || control is! SoundEventControlApi) return;
    final operation = ++_epoch;
    state = SoundEventViewState.busy;
    notifyListeners();
    try {
      final receipt = await control.updatePolicy(
        authority,
        before,
        notificationsEnabled: notificationsEnabled,
        barkEnabled: barkEnabled,
        noiseEnabled: noiseEnabled,
        mutedUntil: normalizedMute,
      );
      if (!_operationCurrent(operation)) return _stale();
      if (!receipt.exactFor(authority, before)) {
        state = SoundEventViewState.failed;
        notifyListeners();
        return;
      }
      await _readback(operation, receipt.repositoryRevision, (value) {
        return value.policy.revision == receipt.policy.revision &&
            value.policy.notificationsEnabled == notificationsEnabled &&
            value.policy.barkEnabled == barkEnabled &&
            value.policy.noiseEnabled == noiseEnabled &&
            value.policy.mutedUntil == normalizedMute;
      });
    } catch (_) {
      if (!_operationCurrent(operation)) return _stale();
      snapshot = null;
      state = SoundEventViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> refreshSource() async {
    final control = api;
    final before = authority;
    if (!canAct || control is! SoundEventSourceApi) return;
    final operation = ++_epoch;
    state = SoundEventViewState.busy;
    notifyListeners();
    try {
      final response = await control.refreshSource();
      if (!_operationCurrent(operation)) return _stale();
      final next = response.authority;
      if (next.coreId != before.coreId ||
          next.homeId != before.homeId ||
          next.accountId != before.accountId ||
          next.sessionFamilyId != before.sessionFamilyId ||
          next.accountRevision != before.accountRevision ||
          !response.coherentFor(next, _clock().toUtc())) {
        snapshot = null;
        state = SoundEventViewState.failed;
      } else {
        authority = next;
        snapshot = response;
        state = SoundEventViewState.verified;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) return _stale();
      snapshot = null;
      state = SoundEventViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> markFeedback(SoundEventItem event, String classification) async {
    final before = snapshot;
    final control = api;
    if (!canAct ||
        before == null ||
        control is! SoundEventControlApi ||
        !before.events.any((candidate) => identical(candidate, event))) {
      return;
    }
    final operation = ++_epoch;
    state = SoundEventViewState.busy;
    notifyListeners();
    try {
      final receipt = await control.feedback(
        authority,
        before,
        event,
        classification,
      );
      if (!_operationCurrent(operation)) return _stale();
      if (!receipt.exactFor(authority, before, event, classification)) {
        state = SoundEventViewState.failed;
        notifyListeners();
        return;
      }
      await _readback(operation, receipt.repositoryRevision, (value) {
        final matches = value.events.where(
          (candidate) => candidate.eventId == event.eventId,
        );
        return matches.length == 1 &&
            matches.single.eventRevision == receipt.eventRevision &&
            matches.single.feedback == classification;
      });
    } catch (_) {
      if (!_operationCurrent(operation)) return _stale();
      snapshot = null;
      state = SoundEventViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _readback(
    int operation,
    int repositoryRevision,
    bool Function(SoundEventSnapshot value) verify,
  ) async {
    final nextAuthority = authority.withRepositoryRevision(repositoryRevision);
    final readback = await api.load(nextAuthority, filter);
    if (!_operationCurrent(operation)) return _stale();
    if (!readback.coherentFor(nextAuthority, _clock().toUtc()) ||
        !verify(readback)) {
      snapshot = null;
      state = SoundEventViewState.failed;
      return;
    }
    authority = nextAuthority;
    snapshot = readback;
    state = SoundEventViewState.verified;
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    snapshot = null;
    super.dispose();
  }
}
