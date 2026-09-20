import '../../server/data/larenor_server_api.dart';
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
