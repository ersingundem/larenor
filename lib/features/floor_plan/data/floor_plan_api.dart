import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/floor_plan_models.dart';

abstract interface class FloorPlanGateway {
  Future<FloorPlanSnapshot> read();
}

final class FloorPlanApi implements FloorPlanGateway {
  const FloorPlanApi(this._api, this._token, this._context);
  final LarenorServerApi _api;
  final String _token;
  final ServerContext _context;

  @override
  Future<FloorPlanSnapshot> read() async => FloorPlanSnapshot.fromResponse(
    await _api.request(
      'GET',
      '/floor-plan/${_context.coreId}/${_context.homeId}',
      token: _token,
    ),
    expected: _context,
  );
}

final class FloorPlanAccountGateway implements FloorPlanGateway {
  FloorPlanAccountGateway({
    required this.account,
    required this.context,
    required this.isCurrent,
    ServerApiFactory? apiFactory,
  }) : _generation = account.generation,
       _endpoint = account.session!.endpoint,
       _api = (apiFactory ?? ((endpoint) => LarenorServerApi(endpoint: endpoint)))(
         account.session!.endpoint,
       );

  final ServerAccountController account;
  final ServerContext context;
  final bool Function() isCurrent;
  final int _generation;
  final ServerEndpoint _endpoint;
  final LarenorServerApi _api;
  bool _closed = false;

  @override
  Future<FloorPlanSnapshot> read() async {
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
    final result = await FloorPlanApi(_api, session.accessToken, context).read();
    if (_closed || !isCurrent() || !account.isCurrent(_generation)) {
      throw const LarenorServerException('cancelled');
    }
    return result;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _api.close();
  }
}
