import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';
import '../domain/home_document_models.dart';

abstract interface class HomeDocumentGateway {
  Future<HomeDocumentPage> search(String query);
  Future<HomeWarrantyReminderPage> reminders(String today);
  Future<HomeDocumentUploadEvidence?> pickAndUpload();
  Future<HomeDocumentCommandResult> create({
    required HomeDocumentPage base,
    required String requestId,
    required HomeDocumentDraft draft,
  });
  Future<HomeDocumentCommandResult> confirmWarranty({
    required HomeDocumentCommandResult created,
    required String requestId,
    required String confirmedDate,
  });
}

enum HomeDocumentFailure {
  offline,
  stale,
  rejected,
  invalidResponse,
  invalidInput,
}

final class HomeDocumentController extends ChangeNotifier {
  HomeDocumentController({
    required this.gateway,
    required this.context,
    required this.accountId,
    required this.isAdmin,
    required this.isCurrent,
    required this.requestIdFactory,
    required this.documentIdFactory,
    DateTime Function()? today,
  }) : _today = today ?? DateTime.now;

  final HomeDocumentGateway gateway;
  final ServerContext context;
  final String accountId;
  final bool isAdmin;
  final bool Function() isCurrent;
  final String Function() requestIdFactory, documentIdFactory;
  final DateTime Function() _today;
  int _epoch = 0;
  bool _active = true, _disposed = false;
  String? _family;
  bool busy = false;
  HomeDocumentFailure? failure;
  HomeDocumentPage? page;
  HomeWarrantyReminderPage? reminderPage;
  HomeDocumentUploadEvidence? upload;

  bool _current() {
    try {
      return !_disposed && _active && isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool get canUpload => isAdmin && !busy && _current() && page != null;
  bool get canPublish => canUpload && upload != null;

  void _clear(HomeDocumentFailure next) {
    busy = false;
    page = null;
    reminderPage = null;
    upload = null;
    _family = null;
    failure = next;
  }

  void setActive(bool value) {
    if (_disposed || _active == value) return;
    _active = value;
    _epoch++;
    if (!value) _clear(HomeDocumentFailure.stale);
    if (value) failure = null;
    notifyListeners();
  }

  HomeDocumentFailure _map(Object error) =>
      error is LarenorServerException &&
          {
            'connection_failed',
            'timeout',
            'server_unavailable',
          }.contains(error.code)
      ? HomeDocumentFailure.offline
      : error is LarenorServerException &&
            {
              'forbidden',
              'unauthorized',
              'revision_conflict',
            }.contains(error.code)
      ? HomeDocumentFailure.rejected
      : HomeDocumentFailure.invalidResponse;

  bool _authority(HomeDocumentAuthority value) {
    if (value.context != context || value.accountId != accountId) return false;
    if (_family != null && value.sessionFamilyId != _family) return false;
    _family ??= value.sessionFamilyId;
    return true;
  }

  String _date() {
    final value = _today().toLocal();
    return '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  }

  Future<void> load({String query = ''}) async {
    if (busy) return;
    if (!_current()) {
      if (!_disposed) {
        _epoch++;
        _clear(HomeDocumentFailure.stale);
        notifyListeners();
      }
      return;
    }
    final operation = ++_epoch;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final next = await gateway.search(query);
      final reminders = await gateway.reminders(_date());
      if (!_current() || operation != _epoch) return _stale(operation);
      if (!_authority(next.authority) ||
          !_authority(reminders.authority) ||
          !next.authority.sameSession(reminders.authority) ||
          next.authority.libraryRevision !=
              reminders.authority.libraryRevision) {
        throw const LarenorServerException('invalid_response');
      }
      page = next;
      reminderPage = reminders;
      upload = null;
    } catch (error) {
      if (!_current() || operation != _epoch) return _stale(operation);
      _clear(_map(error));
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> stageUpload() async {
    if (!canUpload) return;
    final operation = ++_epoch;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final next = await gateway.pickAndUpload();
      if (!_current() || operation != _epoch) return _stale(operation);
      upload = next;
    } catch (error) {
      if (!_current() || operation != _epoch) return _stale(operation);
      upload = null;
      failure = _map(error);
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> publish({
    required String title,
    required HomeDocumentKind kind,
    required String inventoryItemId,
    required List<String> readerIds,
    required bool confirmWarranty,
    required String? warrantyDate,
  }) async {
    final base = page;
    final evidence = upload;
    if (!canPublish || base == null || evidence == null) return;
    HomeDocumentDraft draft;
    try {
      draft = HomeDocumentDraft(
        documentId: documentIdFactory(),
        title: title,
        kind: kind,
        inventoryItemId: inventoryItemId,
        upload: evidence,
        readerIds: readerIds,
        reminderLeadDays: const [30, 7],
      );
      if (confirmWarranty) {
        final parsed = warrantyDate == null
            ? null
            : DateTime.tryParse(warrantyDate);
        final canonical = parsed == null
            ? null
            : '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
        if (warrantyDate == null || canonical != warrantyDate) {
          throw const LarenorServerException('invalid_request');
        }
      }
    } catch (_) {
      failure = HomeDocumentFailure.invalidInput;
      notifyListeners();
      return;
    }
    final operation = ++_epoch;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      var result = await gateway.create(
        base: base,
        requestId: requestIdFactory(),
        draft: draft,
      );
      if (!_current() || operation != _epoch) return _stale(operation);
      if (!_authority(result.authority) ||
          result.document.warranty.confirmedDate != null) {
        throw const LarenorServerException('invalid_response');
      }
      if (confirmWarranty) {
        result = await gateway.confirmWarranty(
          created: result,
          requestId: requestIdFactory(),
          confirmedDate: warrantyDate!,
        );
        if (!_current() || operation != _epoch) return _stale(operation);
        if (!_authority(result.authority) ||
            result.document.warranty.confirmedDate != warrantyDate) {
          throw const LarenorServerException('invalid_response');
        }
      }
      final readback = await gateway.search('');
      final reminders = await gateway.reminders(_date());
      if (!_current() || operation != _epoch) return _stale(operation);
      final match = readback.items
          .where((item) => item.id == result.document.id)
          .toList();
      if (!_authority(readback.authority) ||
          !_authority(reminders.authority) ||
          !readback.authority.sameSession(result.authority) ||
          !reminders.authority.sameSession(result.authority) ||
          readback.authority.libraryRevision !=
              result.authority.libraryRevision ||
          reminders.authority.libraryRevision !=
              result.authority.libraryRevision ||
          match.length != 1 ||
          match.single.revision != result.document.revision ||
          match.single.warranty.confirmedDate !=
              result.document.warranty.confirmedDate) {
        throw const LarenorServerException('invalid_response');
      }
      page = readback;
      reminderPage = reminders;
      upload = null;
    } catch (error) {
      if (!_current() || operation != _epoch) return _stale(operation);
      _clear(_map(error));
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void _stale(int operation) {
    if (_disposed || operation != _epoch) return;
    _clear(HomeDocumentFailure.stale);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}
