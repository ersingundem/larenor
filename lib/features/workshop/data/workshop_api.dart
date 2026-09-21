import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/workshop_models.dart';

final class WorkshopApi implements WorkshopGateway {
  WorkshopApi(this._api, this._session, {required bool Function() isCurrent})
    : _current = isCurrent;

  final LarenorServerApi _api;
  final ServerSession _session;
  final bool Function() _current;
  bool _retired = false;

  ServerContext get _context => _session.context!;
  String get _root => '/workshop/${_context.coreId}/${_context.homeId}';

  void _check() {
    try {
      if (!_retired &&
          _session.context != null &&
          _session.user.canAdminister &&
          _current()) {
        return;
      }
    } catch (_) {}
    _retired = true;
    throw const LarenorServerException('cancelled');
  }

  Future<T> _operation<T>(Future<T> Function() action) async {
    _check();
    try {
      final result = await action();
      _check();
      return result;
    } catch (_) {
      _check();
      rethrow;
    }
  }

  @override
  Future<List<WorkshopPrinter>> load() => _operation(() async {
    final body = serverObject(
      await _api.request('GET', '$_root/printers', token: _session.accessToken),
    );
    if (body.length != 2 || body['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final values = body['printers'];
    if (values is! List || values.length > 64) {
      throw const LarenorServerException('invalid_response');
    }
    final result = values
        .map((value) => WorkshopPrinter.fromJson(value, _context))
        .toList(growable: false);
    final identities = result.map((value) => value.id).toSet();
    if (identities.length != result.length) {
      throw const LarenorServerException('invalid_response');
    }
    return List.unmodifiable(result);
  });

  @override
  Future<WorkshopPreview> preview({
    required WorkshopPrinter printer,
    required WorkshopAction action,
    required String requestKey,
  }) => _operation(() async {
    if (printer.coreId != _context.coreId ||
        printer.homeId != _context.homeId ||
        !printer.availableActions.contains(action) ||
        requestKey.length < 16 ||
        requestKey.length > 128 ||
        !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(requestKey)) {
      throw const LarenorServerException('invalid_request');
    }
    final response = await _api.request(
      'POST',
      '$_root/printers/${printer.id}/previews',
      token: _session.accessToken,
      body: {
        'schemaVersion': 1,
        'expectedPrinterRevision': printer.revision,
        'expectedServiceRevision': printer.service.revision,
        'expectedJobRevision': printer.job.revision,
        'expectedMaterialRevision': printer.material.revision,
        'expectedSafetyRevision': printer.safety.revision,
        'requestKey': requestKey,
        'action': action.name,
      },
    );
    return WorkshopPreview.fromJson(
      response,
      _context,
      printerId: printer.id,
      action: action,
    );
  });

  @override
  Future<WorkshopIntentReceipt> confirm(WorkshopPreview preview) =>
      _operation(() async {
        if (preview.coreId != _context.coreId ||
            preview.homeId != _context.homeId) {
          throw const LarenorServerException('invalid_request');
        }
        final response = await _api.request(
          'POST',
          '$_root/printers/${preview.printerId}/previews/${preview.id}/confirm',
          token: _session.accessToken,
          body: {
            'schemaVersion': 1,
            'confirmationToken': preview.confirmationToken,
          },
        );
        return WorkshopIntentReceipt.fromJson(
          response,
          _context,
          printerId: preview.printerId,
          action: preview.action,
        );
      });

  @override
  void retire() => _retired = true;

  @override
  String toString() => 'WorkshopApi';
}
