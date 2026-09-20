import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/inventory_models.dart';

abstract interface class InventoryGateway {
  Future<InventoryItem> resolve(InventoryQr qr);
  Future<InventoryHistory> history(InventoryItem item);
  Future<InventoryGrants> grants(InventoryItem item);
}

/// Read-only F34 transport. It exposes no inventory or device mutation method.
final class InventoryApi implements InventoryGateway {
  const InventoryApi(this._api, this._token, this._context);
  final LarenorServerApi _api;
  final String _token;
  final ServerContext _context;
  String get _root => '/inventory/${_context.coreId}/${_context.homeId}';

  @override
  Future<InventoryItem> resolve(InventoryQr qr) async {
    if (qr.context != _context) {
      throw const LarenorServerException('invalid_request');
    }
    return InventoryItem.fromResponse(
      await _api.request(
        'POST',
        '$_root/qr/resolve',
        token: _token,
        body: qr.toJson(),
      ),
      expected: _context,
    );
  }

  @override
  Future<InventoryHistory> history(InventoryItem item) async {
    _target(item);
    return InventoryHistory.fromResponse(
      await _api.request(
        'GET',
        '$_root/items/${item.id}/history',
        token: _token,
      ),
      expectedItem: item,
    );
  }

  @override
  Future<InventoryGrants> grants(InventoryItem item) async {
    _target(item);
    return InventoryGrants.fromResponse(
      await _api.request(
        'GET',
        '$_root/items/${item.id}/grants',
        token: _token,
      ),
      expectedItem: item,
    );
  }

  void _target(InventoryItem item) {
    if (item.context != _context) {
      throw const LarenorServerException('invalid_request');
    }
  }
}

/// Refresh-aware route-owned gateway. Every read revalidates the account and
/// exact Core/home authority before using the captured endpoint.
final class InventoryAccountGateway implements InventoryGateway {
  InventoryAccountGateway({
    required this.account,
    required this.context,
    required this.isCurrent,
    ServerApiFactory? apiFactory,
  }) : _generation = account.generation,
       _endpoint = account.session!.endpoint,
       _api =
           (apiFactory ?? ((endpoint) => LarenorServerApi(endpoint: endpoint)))(
             account.session!.endpoint,
           );

  final ServerAccountController account;
  final ServerContext context;
  final bool Function() isCurrent;
  final int _generation;
  final ServerEndpoint _endpoint;
  final LarenorServerApi _api;
  bool _closed = false;

  Future<InventoryApi> _authorized() async {
    if (_closed || !isCurrent() || !account.isCurrent(_generation)) {
      throw const LarenorServerException('cancelled');
    }
    final session = await account.ensureSession();
    if (_closed ||
        !isCurrent() ||
        !account.isCurrent(_generation) ||
        session.context != context ||
        session.endpoint.baseUrl != _endpoint.baseUrl) {
      throw const LarenorServerException('cancelled');
    }
    return InventoryApi(_api, session.accessToken, context);
  }

  @override
  Future<InventoryItem> resolve(InventoryQr qr) async =>
      (await _authorized()).resolve(qr);
  @override
  Future<InventoryHistory> history(InventoryItem item) async =>
      (await _authorized()).history(item);
  @override
  Future<InventoryGrants> grants(InventoryItem item) async =>
      (await _authorized()).grants(item);

  void close() {
    if (_closed) return;
    _closed = true;
    _api.close();
  }
}
