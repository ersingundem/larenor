import 'package:flutter/foundation.dart';

import '../domain/workshop_models.dart';

enum WorkshopFailure {
  unavailable,
  staleAuthority,
  invalidResponse,
  actionUncertain,
}

final class WorkshopController extends ChangeNotifier {
  WorkshopController({
    required WorkshopGateway gateway,
    required bool Function() isCurrent,
    required String Function() requestKey,
  }) : this._(gateway, isCurrent, requestKey);

  WorkshopController._(this._gateway, this._isCurrent, this._requestKey);

  final WorkshopGateway _gateway;
  final bool Function() _isCurrent;
  final String Function() _requestKey;
  List<WorkshopPrinter> _printers = const [];
  List<WorkshopServiceCandidate> _services = const [];
  WorkshopFailure? _failure;
  WorkshopPreview? _pending;
  WorkshopPrinter? _pendingPrinter;
  WorkshopIntentReceipt? _lastReceipt;
  bool _busy = false, _loaded = false, _retired = false;
  int _epoch = 0;

  List<WorkshopPrinter> get printers => _printers;
  List<WorkshopServiceCandidate> get services => _services;
  WorkshopFailure? get failure => _failure;
  WorkshopPreview? get pending => _pending;
  WorkshopIntentReceipt? get lastReceipt => _lastReceipt;
  bool get busy => _busy;
  bool get loaded => _loaded;

  bool _current() {
    if (_retired) return false;
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _emit() {
    if (!_retired) notifyListeners();
  }

  Future<void> refresh() async {
    if (_busy || !_current()) return;
    final operation = ++_epoch;
    _busy = true;
    _loaded = false;
    _failure = null;
    _printers = const [];
    _services = const [];
    _pending = null;
    _pendingPrinter = null;
    _emit();
    try {
      final services = await _gateway.catalog();
      if (operation != _epoch || !_current()) {
        if (!_retired) _failure = WorkshopFailure.staleAuthority;
        return;
      }
      final values = await _gateway.load();
      if (operation != _epoch || !_current()) {
        if (!_retired) {
          _printers = const [];
          _failure = WorkshopFailure.staleAuthority;
        }
        return;
      }
      _printers = List.unmodifiable(values);
      _services = List.unmodifiable(services);
      _loaded = true;
    } catch (_) {
      if (operation == _epoch && _current()) {
        _failure = WorkshopFailure.unavailable;
      }
    } finally {
      if (operation == _epoch && !_retired) {
        _busy = false;
        _emit();
      }
    }
  }

  Future<bool> register(WorkshopServiceCandidate service, String name) async {
    final normalized = name.trim();
    final matches = _services.where(
      (value) => value.id == service.id && value.revision == service.revision,
    );
    if (_busy ||
        !_current() ||
        normalized.isEmpty ||
        normalized.length > 80 ||
        normalized.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f) ||
        matches.length != 1) {
      return false;
    }
    // A verified OctoPrint/Moonraker service represents one printer. Reusing
    // its stable identity keeps a lost registration acknowledgement replayable
    // across controller and application restarts.
    final registrationId = service.id;
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(registrationId)) return false;
    final operation = ++_epoch;
    _busy = true;
    _failure = null;
    _emit();
    try {
      final printer = await _gateway.register(
        service: service,
        name: normalized,
        registrationId: registrationId,
      );
      if (operation != _epoch ||
          !_current() ||
          printer.id != registrationId ||
          printer.name != normalized ||
          printer.service.id != service.id ||
          printer.service.revision != service.revision) {
        if (!_retired) _failure = WorkshopFailure.staleAuthority;
        return false;
      }
      _printers = List.unmodifiable(
        [..._printers.where((value) => value.id != printer.id), printer]
          ..sort((a, b) {
            final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
            return name == 0 ? a.id.compareTo(b.id) : name;
          }),
      );
      _loaded = true;
      return true;
    } catch (_) {
      if (operation == _epoch && _current()) {
        _failure = WorkshopFailure.unavailable;
      }
      return false;
    } finally {
      if (operation == _epoch && !_retired) {
        _busy = false;
        _emit();
      }
    }
  }

  Future<WorkshopPreview?> requestAction(
    WorkshopPrinter printer,
    WorkshopAction action,
  ) async {
    if (_busy || !_current() || !printer.safety.stoppingEligible) return null;
    final authoritative = _printers.where((value) => value.id == printer.id);
    if (authoritative.length != 1 ||
        !authoritative.single.sameAuthority(printer) ||
        !printer.availableActions.contains(action)) {
      return null;
    }
    final operation = ++_epoch;
    _busy = true;
    _failure = null;
    _pending = null;
    _pendingPrinter = null;
    _emit();
    try {
      final preview = await _gateway.preview(
        printer: printer,
        action: action,
        requestKey: _requestKey(),
      );
      if (operation != _epoch ||
          !_current() ||
          preview.coreId != printer.coreId ||
          preview.homeId != printer.homeId ||
          preview.printerId != printer.id ||
          preview.action != action ||
          !preview.expiresAt.isAfter(DateTime.now().toUtc())) {
        if (!_retired) _failure = WorkshopFailure.staleAuthority;
        return null;
      }
      _pending = preview;
      _pendingPrinter = printer;
      return preview;
    } catch (_) {
      if (operation == _epoch && _current()) {
        _failure = WorkshopFailure.unavailable;
      }
      return null;
    } finally {
      if (operation == _epoch && !_retired) {
        _busy = false;
        _emit();
      }
    }
  }

  Future<bool> confirm(WorkshopPreview preview) async {
    final printer = _pendingPrinter;
    if (_busy ||
        !_current() ||
        printer == null ||
        !identical(preview, _pending) ||
        preview.expiresAt.isBefore(DateTime.now().toUtc())) {
      return false;
    }
    final operation = ++_epoch;
    _busy = true;
    _pending = null;
    _pendingPrinter = null;
    _failure = null;
    _emit();
    try {
      final receipt = await _gateway.confirm(preview);
      if (operation != _epoch ||
          !_current() ||
          receipt.printerId != printer.id ||
          receipt.action != preview.action ||
          receipt.effect == WorkshopIntentEffect.unknown ||
          !receipt.authority.matches(printer)) {
        if (!_retired) _failure = WorkshopFailure.actionUncertain;
        return false;
      }
      _lastReceipt = receipt;
      return true;
    } catch (_) {
      if (operation == _epoch && _current()) {
        _failure = WorkshopFailure.actionUncertain;
      }
      return false;
    } finally {
      if (operation == _epoch && !_retired) {
        _busy = false;
        _emit();
      }
    }
  }

  void cancelPreview(WorkshopPreview preview) {
    if (!identical(preview, _pending)) return;
    _pending = null;
    _pendingPrinter = null;
    _emit();
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    _busy = false;
    _printers = const [];
    _services = const [];
    _pending = null;
    _pendingPrinter = null;
    _gateway.retire();
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}
