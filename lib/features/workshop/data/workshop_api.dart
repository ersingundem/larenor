import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
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
        final submitted = WorkshopIntentReceipt.fromJson(
          response,
          _context,
          printerId: preview.printerId,
          action: preview.action,
        );
        final readback = serverObject(
          await _api.request(
            'GET',
            '$_root/printers/${preview.printerId}/intents',
            token: _session.accessToken,
            queryParameters: const {'limit': '100'},
          ),
        );
        if (readback.length != 2 || readback['schemaVersion'] != 1) {
          throw const LarenorServerException('invalid_response');
        }
        final values = readback['intents'];
        if (values is! List || values.length > 100) {
          throw const LarenorServerException('invalid_response');
        }
        final receipts = values
            .map((raw) {
              final value = serverObject(raw);
              final action = switch (value['action']) {
                'pause' => WorkshopAction.pause,
                'cancel' => WorkshopAction.cancel,
                _ => throw const LarenorServerException('invalid_response'),
              };
              return WorkshopIntentReceipt.fromJson(
                {'receipt': value},
                _context,
                printerId: preview.printerId,
                action: action,
              );
            })
            .toList(growable: false);
        final matches = receipts.where((receipt) => receipt.id == submitted.id);
        if (matches.length != 1) {
          throw const LarenorServerException('invalid_response');
        }
        final retained = matches.single;
        if (retained.sequence != submitted.sequence ||
            retained.printerId != submitted.printerId ||
            retained.action != submitted.action ||
            retained.effect != submitted.effect ||
            retained.createdAt != submitted.createdAt ||
            retained.authority.printerRevision !=
                submitted.authority.printerRevision ||
            retained.authority.serviceRevision !=
                submitted.authority.serviceRevision ||
            retained.authority.jobRevision != submitted.authority.jobRevision ||
            retained.authority.materialRevision !=
                submitted.authority.materialRevision ||
            retained.authority.safetyRevision !=
                submitted.authority.safetyRevision) {
          throw const LarenorServerException('invalid_response');
        }
        return retained;
      });

  @override
  void retire() => _retired = true;

  @override
  String toString() => 'WorkshopApi';
}

/// Rebinds every request to the account controller's current authenticated
/// session. The retained route authority must still match after token refresh
/// and after the HTTP response; account/home changes permanently fail closed.
final class AccountWorkshopGateway implements WorkshopGateway {
  AccountWorkshopGateway({
    required ServerAccountController account,
    required bool Function() isCurrent,
  }) : _account = account,
       _current = isCurrent,
       _generation = account.generation,
       _context = account.session?.context,
       _userId = account.session?.user.id,
       _endpoint = account.session?.endpoint.baseUrl;

  final ServerAccountController _account;
  final bool Function() _current;
  final int _generation;
  final ServerContext? _context;
  final String? _userId, _endpoint;
  bool _retired = false;

  bool _valid() {
    if (_retired || !_account.isCurrent(_generation)) return false;
    try {
      final session = _account.session;
      return _current() &&
          session != null &&
          session.context == _context &&
          session.user.id == _userId &&
          session.user.canAdminister &&
          !session.user.mustChangePassword &&
          session.endpoint.baseUrl == _endpoint;
    } catch (_) {
      return false;
    }
  }

  Future<T> _run<T>(Future<T> Function(WorkshopApi api) operation) async {
    if (!_valid()) throw const LarenorServerException('cancelled');
    return _account.withSession((raw, session) async {
      if (!_valid() ||
          session.context != _context ||
          session.user.id != _userId ||
          session.endpoint.baseUrl != _endpoint) {
        throw const LarenorServerException('cancelled');
      }
      final api = WorkshopApi(raw, session, isCurrent: _valid);
      try {
        final result = await operation(api);
        if (!_valid()) throw const LarenorServerException('cancelled');
        return result;
      } finally {
        api.retire();
      }
    });
  }

  @override
  Future<List<WorkshopPrinter>> load() => _run((api) => api.load());

  @override
  Future<WorkshopPreview> preview({
    required WorkshopPrinter printer,
    required WorkshopAction action,
    required String requestKey,
  }) => _run(
    (api) =>
        api.preview(printer: printer, action: action, requestKey: requestKey),
  );

  @override
  Future<WorkshopIntentReceipt> confirm(WorkshopPreview preview) =>
      _run((api) => api.confirm(preview));

  @override
  void retire() => _retired = true;
}
