import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/resource_reservation_models.dart';

enum ReservationViewState {
  detached,
  idle,
  loading,
  empty,
  ready,
  busy,
  uncertain,
  conflict,
  offline,
  error,
}

class ReservationLease {
  const ReservationLease._(this.epoch, this.authority);

  final int epoch;
  final ResourceReservationAuthority authority;
}

class _PendingReservation {
  const _PendingReservation({
    required this.commandId,
    required this.action,
    required this.expectedCalendarRevision,
    this.draft,
    this.reservation,
  });

  final String commandId;
  final ReservationAction action;
  final int expectedCalendarRevision;
  final ReservationDraft? draft;
  final ResourceReservationItem? reservation;
}

class ResourceReservationController extends ChangeNotifier {
  ResourceReservationController(
    this._api, {
    required this.commandIds,
    this.onAuthorityChanged,
  });

  static const exportLimit = 256;

  final ResourceReservationApi _api;
  final String Function() commandIds;
  final VoidCallback? onAuthorityChanged;
  ResourceReservationAuthority? _authority;
  ReservationViewState _state = ReservationViewState.detached;
  ReservationResource? _resource;
  List<ResourceReservationItem> _reservations = const [];
  List<ReservationHistoryItem> _history = const [];
  List<ReservationBusyWindow> _busy = const [];
  List<ResourceReservationItem> _exported = const [];
  int? _calendarRevision;
  int _totalReservations = 0;
  bool _reservationsTruncated = false;
  bool _historyTruncated = false;
  bool _busyTruncated = false;
  bool _canCreate = false;
  int _epoch = 0;
  _PendingReservation? _pending;

  ResourceReservationAuthority? get authority => _authority;
  ReservationViewState get state => _state;
  ReservationResource? get resource => _resource;
  List<ResourceReservationItem> get reservations =>
      List.unmodifiable(_reservations);
  List<ReservationHistoryItem> get history => List.unmodifiable(_history);
  List<ReservationBusyWindow> get busy => List.unmodifiable(_busy);
  List<ResourceReservationItem> get exported => List.unmodifiable(_exported);
  int? get calendarRevision => _calendarRevision;
  int get totalReservations => _totalReservations;
  bool get reservationsTruncated => _reservationsTruncated;
  bool get historyTruncated => _historyTruncated;
  bool get busyTruncated => _busyTruncated;
  bool get hasBoundedView =>
      _reservationsTruncated || _historyTruncated || _busyTruncated;
  bool get canCreate => _canCreate;

  ReservationLease bind(ResourceReservationAuthority authority) {
    _epoch++;
    _authority = authority;
    _clear();
    _state = ReservationViewState.idle;
    notifyListeners();
    return ReservationLease._(_epoch, authority);
  }

  bool _current(ReservationLease lease) =>
      lease.epoch == _epoch && lease.authority == _authority;

  void detach(ReservationLease lease) {
    if (!_current(lease)) return;
    _epoch++;
    _authority = null;
    _clear();
    _state = ReservationViewState.detached;
    notifyListeners();
  }

  /// Retires every lease before a route/account/window authority is released.
  void retire() {
    _epoch++;
    _authority = null;
    _clear();
    _state = ReservationViewState.detached;
    notifyListeners();
  }

  void _clear() {
    _resource = null;
    _reservations = const [];
    _history = const [];
    _busy = const [];
    _exported = const [];
    _calendarRevision = null;
    _totalReservations = 0;
    _reservationsTruncated = false;
    _historyTruncated = false;
    _busyTruncated = false;
    _canCreate = false;
    _pending = null;
  }

  void _set(ReservationViewState state) {
    _state = state;
    notifyListeners();
  }

  bool _authorityFailure(
    ReservationApiException error,
    ReservationLease lease,
  ) {
    if (error.code != 'authority_changed') return false;
    if (_current(lease)) {
      _clear();
      _set(ReservationViewState.error);
      onAuthorityChanged?.call();
    }
    return true;
  }

  bool _validSnapshot(ReservationSnapshot value, ReservationLease lease) =>
      value.authority == lease.authority &&
      value.calendarRevision > 0 &&
      value.resource.id == lease.authority.resourceId &&
      value.resource.revision == lease.authority.resourceRevision &&
      value.resource.timezone.isNotEmpty &&
      value.resource.capacity >= 1 &&
      value.resource.capacity <= 64 &&
      value.totalReservations >= value.reservations.length &&
      value.reservationsTruncated ==
          (value.totalReservations > value.reservations.length) &&
      value.reservations.length <= exportLimit &&
      value.reservations.map((item) => item.id).toSet().length ==
          value.reservations.length &&
      value.history.length <= exportLimit &&
      (!value.historyTruncated || value.history.length == exportLimit) &&
      value.busy.length <= exportLimit &&
      (!value.busyTruncated || value.busy.length == exportLimit) &&
      value.history.every(
        (item) =>
            item.eventId.isNotEmpty &&
            item.actorId.isNotEmpty &&
            item.reservationId.isNotEmpty &&
            item.calendarRevision > 0 &&
            item.calendarRevision <= value.calendarRevision,
      ) &&
      Iterable<int>.generate(value.history.length).every(
        (index) =>
            index == 0 ||
            value.history[index - 1].calendarRevision <
                value.history[index].calendarRevision,
      ) &&
      value.busy.every(
        (item) =>
            item.units >= 1 &&
            item.units <= value.resource.capacity &&
            _validWindow(item.startUtc, item.endUtc),
      ) &&
      value.reservations.every(
        (item) =>
            item.id.isNotEmpty &&
            item.resourceId == value.resource.id &&
            item.timezone == value.resource.timezone &&
            item.occurrences.isNotEmpty &&
            item.occurrences.length <= 64 &&
            item.occurrences.every(
              (occurrence) =>
                  _validWindow(occurrence.startUtc, occurrence.endUtc),
            ) &&
            item.units >= 1 &&
            item.units <= value.resource.capacity,
      );

  static bool _validWindow(String start, String end) {
    final canonical = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$');
    if (!canonical.hasMatch(start) || !canonical.hasMatch(end)) return false;
    final startValue = DateTime.tryParse(start);
    final endValue = DateTime.tryParse(end);
    return startValue != null &&
        endValue != null &&
        startValue.isUtc &&
        endValue.isUtc &&
        startValue.isBefore(endValue);
  }

  Future<void> load(ReservationLease lease) async {
    if (!_current(lease) ||
        _state == ReservationViewState.loading ||
        _pending != null) {
      return;
    }
    _set(ReservationViewState.loading);
    try {
      final value = await _api.snapshot(lease.authority);
      if (!_current(lease)) return;
      if (!_validSnapshot(value, lease)) {
        _clear();
        _set(ReservationViewState.error);
        return;
      }
      _resource = value.resource;
      _calendarRevision = value.calendarRevision;
      _totalReservations = value.totalReservations;
      _reservationsTruncated = value.reservationsTruncated;
      _historyTruncated = value.historyTruncated;
      _busyTruncated = value.busyTruncated;
      _canCreate = value.canCreate;
      _reservations = value.reservations;
      _history = value.history;
      _busy = value.busy;
      _exported = const [];
      _set(
        value.reservations.isEmpty
            ? ReservationViewState.empty
            : ReservationViewState.ready,
      );
    } on TimeoutException {
      if (_current(lease)) _set(ReservationViewState.offline);
    } on ReservationApiException catch (error) {
      if (!_authorityFailure(error, lease) && _current(lease)) {
        _set(ReservationViewState.error);
      }
    } catch (_) {
      if (_current(lease)) _set(ReservationViewState.error);
    }
  }

  bool _canMutate(ReservationLease lease) =>
      _current(lease) &&
      _calendarRevision != null &&
      _pending == null &&
      (_state == ReservationViewState.ready ||
          _state == ReservationViewState.empty ||
          _state == ReservationViewState.conflict);

  Future<void> create(ReservationLease lease, ReservationDraft draft) async {
    final resource = _resource;
    final revision = _calendarRevision;
    if (!_canMutate(lease) ||
        !_canCreate ||
        resource == null ||
        revision == null ||
        draft.timezone != resource.timezone ||
        draft.units > resource.capacity) {
      return;
    }
    final pending = _PendingReservation(
      commandId: commandIds(),
      action: ReservationAction.create,
      expectedCalendarRevision: revision,
      draft: draft,
    );
    _pending = pending;
    _set(ReservationViewState.busy);
    try {
      final receipt = await _api.create(
        lease.authority,
        expectedCalendarRevision: revision,
        commandId: pending.commandId,
        draft: draft,
      );
      _acceptIfCurrent(lease, pending, receipt);
    } on TimeoutException {
      if (_current(lease)) _set(ReservationViewState.uncertain);
    } on ReservationApiException catch (error) {
      if (!_current(lease)) return;
      if (_authorityFailure(error, lease)) return;
      _pending = null;
      _set(
        error.code == 'reservation_overlap' || error.code == 'revision_conflict'
            ? ReservationViewState.conflict
            : ReservationViewState.error,
      );
    } catch (_) {
      if (_current(lease)) {
        _pending = null;
        _set(ReservationViewState.error);
      }
    }
  }

  Future<void> cancel(
    ReservationLease lease,
    ResourceReservationItem reservation,
  ) async {
    final revision = _calendarRevision;
    final current = _reservations
        .where((item) => item.id == reservation.id)
        .firstOrNull;
    if (!_canMutate(lease) ||
        revision == null ||
        current == null ||
        current.cancelled ||
        !current.canCancel) {
      return;
    }
    final pending = _PendingReservation(
      commandId: commandIds(),
      action: ReservationAction.cancel,
      expectedCalendarRevision: revision,
      reservation: current,
    );
    _pending = pending;
    _set(ReservationViewState.busy);
    try {
      final receipt = await _api.cancel(
        lease.authority,
        expectedCalendarRevision: revision,
        commandId: pending.commandId,
        reservationId: current.id,
      );
      _acceptIfCurrent(lease, pending, receipt);
    } on TimeoutException {
      if (_current(lease)) _set(ReservationViewState.uncertain);
    } on ReservationApiException catch (error) {
      if (!_current(lease)) return;
      if (_authorityFailure(error, lease)) return;
      _pending = null;
      _set(
        error.code == 'reservation_overlap' || error.code == 'revision_conflict'
            ? ReservationViewState.conflict
            : ReservationViewState.error,
      );
    } catch (_) {
      if (_current(lease)) {
        _pending = null;
        _set(ReservationViewState.error);
      }
    }
  }

  bool _matches(
    ReservationReceipt receipt,
    ReservationLease lease,
    _PendingReservation pending,
  ) {
    if (receipt.authority != lease.authority ||
        receipt.eventId.isEmpty ||
        receipt.actorId != lease.authority.accountId ||
        receipt.commandId != pending.commandId ||
        receipt.action != pending.action ||
        receipt.expectedCalendarRevision != pending.expectedCalendarRevision ||
        receipt.calendarRevision != pending.expectedCalendarRevision + 1) {
      return false;
    }
    return switch (pending.action) {
      ReservationAction.create =>
        pending.draft != null &&
            receipt.reservation.ownerId == lease.authority.accountId &&
            receipt.reservation.resourceId == lease.authority.resourceId &&
            receipt.reservation.matchesDraft(pending.draft!),
      ReservationAction.cancel =>
        pending.reservation != null &&
            _sameReservationContent(
              receipt.reservation,
              pending.reservation!,
            ) &&
            receipt.reservation.cancelled,
    };
  }

  void _acceptIfCurrent(
    ReservationLease lease,
    _PendingReservation pending,
    ReservationReceipt receipt,
  ) {
    if (!_current(lease)) return;
    if (!_matches(receipt, lease, pending)) {
      _pending = null;
      _set(ReservationViewState.error);
      return;
    }
    if (receipt.currentCalendarRevision != receipt.calendarRevision) {
      _pending = null;
      _clear();
      _set(ReservationViewState.error);
      onAuthorityChanged?.call();
      return;
    }
    final without = _reservations
        .where((item) => item.id != receipt.reservation.id)
        .toList();
    final updated = [...without, receipt.reservation];
    _totalReservations += pending.action == ReservationAction.create ? 1 : 0;
    _reservations = List.unmodifiable(
      updated.length > exportLimit
          ? updated.sublist(updated.length - exportLimit)
          : updated,
    );
    _calendarRevision = receipt.calendarRevision;
    _reservationsTruncated = _totalReservations > _reservations.length;
    final history = [
      ..._history,
      ReservationHistoryItem(
        eventId: receipt.eventId,
        action: receipt.action,
        actorId: receipt.actorId,
        reservationId: receipt.reservation.id,
        calendarRevision: receipt.calendarRevision,
      ),
    ];
    _historyTruncated = _historyTruncated || history.length > exportLimit;
    _history = List.unmodifiable(
      history.length > exportLimit
          ? history.sublist(history.length - exportLimit)
          : history,
    );
    _updateBusy(pending, receipt.reservation);
    _exported = const [];
    _pending = null;
    _set(ReservationViewState.ready);
    if (hasBoundedView) unawaited(load(lease));
  }

  void _updateBusy(
    _PendingReservation pending,
    ResourceReservationItem reservation,
  ) {
    if (_busyTruncated) return;
    final values = [..._busy];
    if (pending.action == ReservationAction.create) {
      values.addAll(
        reservation.occurrences.map(
          (item) => ReservationBusyWindow(
            startUtc: item.startUtc,
            endUtc: item.endUtc,
            units: reservation.units,
          ),
        ),
      );
    } else {
      for (final occurrence in reservation.occurrences) {
        final index = values.indexWhere(
          (item) =>
              item.startUtc == occurrence.startUtc &&
              item.endUtc == occurrence.endUtc &&
              item.units == reservation.units,
        );
        if (index >= 0) values.removeAt(index);
      }
    }
    values.sort((left, right) {
      final start = left.startUtc.compareTo(right.startUtc);
      return start != 0 ? start : left.endUtc.compareTo(right.endUtc);
    });
    _busy = List.unmodifiable(values);
  }

  Future<void> reconcile(ReservationLease lease) async {
    final pending = _pending;
    if (!_current(lease) ||
        pending == null ||
        _state != ReservationViewState.uncertain) {
      return;
    }
    try {
      final receipt = await _api.receipt(lease.authority, pending.commandId);
      if (!_current(lease) || receipt == null) return;
      _acceptIfCurrent(lease, pending, receipt);
    } on TimeoutException {
      // Preserve the single uncertain command. A write is never replayed.
    } on ReservationApiException catch (error) {
      if (!_authorityFailure(error, lease) && _current(lease)) {
        _set(ReservationViewState.uncertain);
      }
    } catch (_) {
      if (_current(lease)) _set(ReservationViewState.uncertain);
    }
  }

  bool _sameReservationContent(
    ResourceReservationItem left,
    ResourceReservationItem right,
  ) =>
      left.id == right.id &&
      left.ownerId == right.ownerId &&
      left.resourceId == right.resourceId &&
      left.timezone == right.timezone &&
      left.localStart == right.localStart &&
      left.fold == right.fold &&
      left.durationSeconds == right.durationSeconds &&
      left.units == right.units &&
      left.recurrence == right.recurrence &&
      left.occurrences.length == right.occurrences.length &&
      Iterable<int>.generate(left.occurrences.length).every(
        (index) =>
            left.occurrences[index].startUtc ==
                right.occurrences[index].startUtc &&
            left.occurrences[index].endUtc == right.occurrences[index].endUtc,
      );

  Future<void> readExport(ReservationLease lease) async {
    final revision = _calendarRevision;
    if (!_canMutate(lease) || revision == null) return;
    try {
      final value = await _api.export(
        lease.authority,
        expectedCalendarRevision: revision,
        limit: exportLimit,
      );
      if (!_current(lease)) return;
      if (value.authority != lease.authority ||
          value.calendarRevision != revision ||
          value.reservations.length > exportLimit ||
          value.reservations.any(
            (item) => !_reservations.any(
              (current) =>
                  _sameReservationContent(item, current) &&
                  item.cancelled == current.cancelled &&
                  item.canCancel == current.canCancel,
            ),
          )) {
        _exported = const [];
        _set(ReservationViewState.error);
        return;
      }
      _exported = value.reservations;
      notifyListeners();
    } on TimeoutException {
      if (_current(lease)) _set(ReservationViewState.offline);
    } on ReservationApiException catch (error) {
      if (!_authorityFailure(error, lease) && _current(lease)) {
        _set(ReservationViewState.error);
      }
    } catch (_) {
      if (_current(lease)) _set(ReservationViewState.error);
    }
  }
}
