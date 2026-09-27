import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/pantry_stock_models.dart';

final class PantryStockAccountApi {
  PantryStockAccountApi({
    required this.account,
    required this.context,
    required this.isCurrent,
  }) : _generation = account.generation;

  final ServerAccountController account;
  final ServerContext context;
  final bool Function() isCurrent;
  final int _generation;
  bool _closed = false;

  String get _root => '/pantry/${context.coreId}/${context.homeId}';

  Future<Map<String, dynamic>?> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (_closed || !isCurrent() || !account.isCurrent(_generation)) {
      throw const LarenorServerException('cancelled');
    }
    final result = await account.withSession((api, session) {
      if (session.context != context || !isCurrent()) {
        throw const LarenorServerException('cancelled');
      }
      return api.request(method, path, token: session.accessToken, body: body);
    });
    if (_closed || !isCurrent() || !account.isCurrent(_generation)) {
      throw const LarenorServerException('cancelled');
    }
    return result;
  }

  Future<PantrySnapshot> snapshot() async => PantrySnapshot.fromResponse(
    await _request('GET', _root),
    expected: context,
  );

  Future<PantryMutation> receive({
    required String requestId,
    required int expectedRevision,
    required PantryLotDraft lot,
  }) async => PantryMutation.fromResponse(
    await _request(
      'POST',
      '$_root/receive',
      body: {
        'schemaVersion': 1,
        'requestId': requestId,
        'expectedRevision': expectedRevision,
        'lot': lot.toJson(),
      },
    ),
    expected: context,
  );

  Future<PantryMutation> consume({
    required String requestId,
    required int expectedRevision,
    required String ingredientKey,
    required PantryAmount amount,
  }) async => PantryMutation.fromResponse(
    await _request(
      'POST',
      '$_root/consume',
      body: {
        'schemaVersion': 1,
        'requestId': requestId,
        'expectedRevision': expectedRevision,
        'ingredientKey': ingredientKey,
        'amount': amount.toJson(),
      },
    ),
    expected: context,
  );

  Future<PantryMutation> undo({
    required String requestId,
    required int expectedRevision,
    required String movementId,
  }) async => PantryMutation.fromResponse(
    await _request(
      'POST',
      '$_root/undo',
      body: {
        'schemaVersion': 1,
        'requestId': requestId,
        'expectedRevision': expectedRevision,
        'movementId': movementId,
      },
    ),
    expected: context,
  );

  void close() => _closed = true;
}
