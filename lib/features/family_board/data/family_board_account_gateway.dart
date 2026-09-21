import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/family_board_models.dart';
import 'family_board_api.dart';
import 'family_board_controller.dart';

/// Route-owned gateway. It validates endpoint, Core/home, account generation,
/// member/session binding and route/lifecycle authority before and after every call.
final class FamilyBoardAccountGateway implements FamilyBoardGateway {
  FamilyBoardAccountGateway({
    required this.account,
    required this.binding,
    required this.isCurrent,
    ServerApiFactory? apiFactory,
  }) : _generation = account.generation,
       _endpoint = account.session!.endpoint,
       _api =
           (apiFactory ?? ((endpoint) => LarenorServerApi(endpoint: endpoint)))(
             account.session!.endpoint,
           );
  final ServerAccountController account;
  final FamilyBoardBinding binding;
  final bool Function(FamilyBoardBinding) isCurrent;
  final int _generation;
  final ServerEndpoint _endpoint;
  final LarenorServerApi _api;
  bool _closed = false;

  static Future<FamilyBoardBinding> loadBinding({
    required ServerAccountController account,
    required ServerContext context,
    required int routeRevision,
    required int lifecycleRevision,
    required bool Function() isCurrent,
    ServerApiFactory? apiFactory,
  }) async {
    final generation = account.generation;
    final endpoint = account.session?.endpoint;
    if (endpoint == null || !isCurrent() || !account.isCurrent(generation)) {
      throw const FamilyBoardException('cancelled');
    }
    final api = (apiFactory ?? ((value) => LarenorServerApi(endpoint: value)))(
      endpoint,
    );
    try {
      final session = await account.ensureSession();
      if (!isCurrent() ||
          !account.isCurrent(generation) ||
          session.context != context ||
          session.endpoint.baseUrl != endpoint.baseUrl) {
        throw const FamilyBoardException('cancelled');
      }
      final raw = await api.request(
        'GET',
        '/family-boards/${context.coreId}/${context.homeId}/authority',
        token: session.accessToken,
      );
      if (!isCurrent() || !account.isCurrent(generation)) {
        throw const FamilyBoardException('cancelled');
      }
      return FamilyBoardBinding.fromAuthority(
        raw,
        coreId: context.coreId,
        homeId: context.homeId,
        accountId: session.user.id,
        routeRevision: routeRevision,
        lifecycleRevision: lifecycleRevision,
      );
    } on LarenorServerException catch (error) {
      throw FamilyBoardException(error.code);
    } finally {
      api.close();
    }
  }

  Future<FamilyBoardApi> _authorized() async {
    bool current() {
      try {
        return !_closed &&
            binding.active &&
            isCurrent(binding) &&
            account.isCurrent(_generation);
      } catch (_) {
        return false;
      }
    }

    if (!current()) throw const FamilyBoardException('cancelled');
    final session = await account.ensureSession();
    final context = session.context;
    if (!current() ||
        context == null ||
        context.coreId != binding.coreId ||
        context.homeId != binding.homeId ||
        session.endpoint.baseUrl != _endpoint.baseUrl ||
        session.user.id != binding.accountId) {
      throw const FamilyBoardException('cancelled');
    }
    return FamilyBoardApi(_api, session.accessToken, binding);
  }

  Future<T> _operation<T>(Future<T> Function(FamilyBoardApi api) action) async {
    final value = await action(await _authorized());
    await _authorized();
    return value;
  }

  @override
  Future<FamilyBoardSnapshot> read(FamilyBoardBinding authority) {
    _target(authority);
    return _operation((api) => api.read(authority));
  }

  @override
  Future<FamilyBoardDelta> delta(
    FamilyBoardBinding authority, {
    required int afterSequence,
  }) {
    _target(authority);
    return _operation(
      (api) => api.delta(authority, afterSequence: afterSequence),
    );
  }

  @override
  Future<FamilyBoardReceipt> mutate(
    FamilyBoardBinding authority,
    FamilyBoardCommand command,
  ) {
    _target(authority);
    return _operation((api) => api.mutate(authority, command));
  }

  void _target(FamilyBoardBinding authority) {
    if (authority != binding) throw const FamilyBoardException('cancelled');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _api.close();
  }
}
