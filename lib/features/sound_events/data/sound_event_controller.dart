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

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    snapshot = null;
    super.dispose();
  }
}
