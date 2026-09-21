import 'package:flutter/foundation.dart';

import '../domain/room_comfort_models.dart';

enum RoomComfortFailure { unavailable, staleAuthority, invalidScope }

final class RoomComfortController extends ChangeNotifier {
  static final _identity = RegExp(r'^[0-9a-f]{32}$');

  RoomComfortController({
    required RoomComfortGateway gateway,
    required bool Function() isCurrent,
    required String coreId,
    required String homeId,
    required String Function() requestId,
  }) : this._(gateway, isCurrent, coreId, homeId, requestId);

  RoomComfortController._(
    this._gateway,
    this._isCurrent,
    this._coreId,
    this._homeId,
    this._requestId,
  );

  final RoomComfortGateway _gateway;
  final bool Function() _isCurrent;
  final String _coreId, _homeId;
  final String Function() _requestId;
  RoomComfortPlan? _plan;
  RoomComfortPreview? _preview;
  RoomComfortReceipt? _receipt;
  RoomComfortFailure? _failure;
  bool _busy = false, _retired = false;
  int _epoch = 0;

  RoomComfortPlan? get plan => _plan;
  RoomComfortFailure? get failure => _failure;
  RoomComfortPreview? get previewValue => _preview;
  RoomComfortReceipt? get receipt => _receipt;
  bool get busy => _busy;

  bool _current() {
    if (_retired) return false;
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }

  Future<void> refresh() async {
    if (_busy || !_current()) return;
    final operation = ++_epoch;
    _busy = true;
    _failure = null;
    _preview = null;
    notifyListeners();
    try {
      final next = await _gateway.loadPlan();
      if (operation != _epoch || !_current()) {
        if (!_retired) {
          _plan = null;
          _failure = RoomComfortFailure.staleAuthority;
        }
        return;
      }
      final ids = next.rooms.map((room) => room.roomId).toSet();
      final exactIdentities = [
        next.coreId,
        next.homeId,
        next.planId,
        next.policyId,
        next.sessionFamilyId,
        for (final room in next.rooms) ...[room.roomId, room.areaId],
      ].every(_identity.hasMatch);
      if (!exactIdentities ||
          next.coreId != _coreId ||
          next.homeId != _homeId ||
          next.homeRevision < 1 ||
          next.policyRevision < 1 ||
          next.accountRevision < 1 ||
          next.rooms.isEmpty ||
          next.rooms.length > 32 ||
          ids.length != next.rooms.length ||
          next.rooms.any(
            (room) => room.roomRevision < 1 || room.areaRevision < 1,
          )) {
        _plan = null;
        _failure = RoomComfortFailure.invalidScope;
        return;
      }
      _plan = RoomComfortPlan(
        coreId: next.coreId,
        homeId: next.homeId,
        planId: next.planId,
        policyId: next.policyId,
        homeRevision: next.homeRevision,
        policyRevision: next.policyRevision,
        accountRevision: next.accountRevision,
        sessionFamilyId: next.sessionFamilyId,
        generatedAt: next.generatedAt,
        rooms: List.unmodifiable(next.rooms),
      );
    } catch (_) {
      if (operation == _epoch && _current()) {
        _plan = null;
        _failure = RoomComfortFailure.unavailable;
      }
    } finally {
      if (operation == _epoch && !_retired) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  Future<RoomComfortPreview?> preview() async {
    final plan = _plan;
    if (_busy ||
        !_current() ||
        plan == null ||
        plan.rooms.every((room) => room.status != ComfortPlanStatus.planned)) {
      return null;
    }
    final operation = ++_epoch;
    _busy = true;
    _failure = null;
    _preview = null;
    notifyListeners();
    try {
      final value = await _gateway.preview(plan, _requestId());
      if (operation != _epoch ||
          !_current() ||
          value.planId != plan.planId ||
          value.policyRevision != plan.policyRevision ||
          !value.expiresAt.isAfter(DateTime.now().toUtc())) {
        if (!_retired) _failure = RoomComfortFailure.staleAuthority;
        return null;
      }
      _preview = value;
      return value;
    } catch (_) {
      if (operation == _epoch && _current()) {
        _failure = RoomComfortFailure.unavailable;
      }
      return null;
    } finally {
      if (operation == _epoch && !_retired) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> confirm(RoomComfortPreview value) async {
    if (_busy ||
        !_current() ||
        !identical(value, _preview) ||
        !value.expiresAt.isAfter(DateTime.now().toUtc())) {
      return false;
    }
    final operation = ++_epoch;
    _busy = true;
    _preview = null;
    _failure = null;
    notifyListeners();
    try {
      final receipt = await _gateway.confirm(value);
      if (operation != _epoch ||
          !_current() ||
          receipt.planId != value.planId ||
          receipt.commandCount != value.commandCount) {
        if (!_retired) _failure = RoomComfortFailure.staleAuthority;
        return false;
      }
      _receipt = receipt;
      return true;
    } catch (_) {
      if (operation == _epoch && _current()) {
        _failure = RoomComfortFailure.unavailable;
      }
      return false;
    } finally {
      if (operation == _epoch && !_retired) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  void cancelPreview(RoomComfortPreview value) {
    if (!identical(value, _preview)) return;
    _preview = null;
    notifyListeners();
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    _busy = false;
    _plan = null;
    _preview = null;
    _gateway.retire();
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}
