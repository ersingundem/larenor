import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/ingredient_deduction.dart';
import 'ingredient_deduction_controller.dart';

final class IngredientDeductionAccountApi
    implements IngredientDeductionGateway {
  IngredientDeductionAccountApi({
    required this.account,
    required this.context,
    required this.preview,
    required this.isCurrent,
  }) : _generation = account.generation;

  final ServerAccountController account;
  final ServerContext context;
  final IngredientDeductionPreview preview;
  final bool Function() isCurrent;
  final int _generation;
  bool _closed = false;

  String get _root =>
      '/cooking/${context.coreId}/${context.homeId}/sessions/'
      '${preview.recipeSessionId}/ingredient-deductions';

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

  @override
  Future<IngredientDeductionReceipt> commit(
    IngredientDeductionPreview value,
  ) async {
    if (!identical(value, preview) &&
        value.idempotencyKey != preview.idempotencyKey) {
      throw const LarenorServerException('invalid_request');
    }
    return IngredientDeductionReceipt.fromResponse(
      await _request('POST', _root, body: preview.toJson()),
      expected: preview,
    );
  }

  @override
  Future<IngredientDeductionReceipt?> receipt(String idempotencyKey) async {
    if (idempotencyKey != preview.idempotencyKey) {
      throw const LarenorServerException('invalid_request');
    }
    try {
      return IngredientDeductionReceipt.fromResponse(
        await _request('GET', '$_root/$idempotencyKey'),
        expected: preview,
      );
    } on LarenorServerException catch (error) {
      if (error.code == 'not_found') return null;
      rethrow;
    }
  }

  void close() => _closed = true;
}
