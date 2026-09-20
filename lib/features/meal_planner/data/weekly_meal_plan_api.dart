import 'dart:convert';

import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/weekly_meal_plan.dart';

abstract interface class WeeklyMealPlanGateway {
  Future<WeeklyMealPlanSnapshot> read();
  Future<WeeklyMealPlanSnapshot> save({
    required WeeklyMealPlanSnapshot base,
    required String requestId,
    required String weekStart,
    required List<MealRecipe> recipes,
    required List<MealPlanEntry> entries,
  });
}

final class WeeklyMealPlanApi implements WeeklyMealPlanGateway {
  const WeeklyMealPlanApi(this._api, this._token, this._context);

  final LarenorServerApi _api;
  final String _token;
  final ServerContext _context;

  String get _path => '/meal-plans/${_context.coreId}/${_context.homeId}';

  @override
  Future<WeeklyMealPlanSnapshot> read() async =>
      WeeklyMealPlanSnapshot.fromJson(
        await _api.request('GET', _path, token: _token),
        _context,
      );

  @override
  Future<WeeklyMealPlanSnapshot> save({
    required WeeklyMealPlanSnapshot base,
    required String requestId,
    required String weekStart,
    required List<MealRecipe> recipes,
    required List<MealPlanEntry> entries,
  }) async {
    if (base.authority.context != _context ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
        recipes.length > 32 ||
        entries.length > 28) {
      throw const LarenorServerException('invalid_request');
    }
    final fields = <String, dynamic>{
      'weekStart': weekStart,
      'recipes': recipes.map((value) => value.toJson()).toList(),
      'entries': entries.map((value) => value.toJson()).toList(),
    };
    final body = <String, dynamic>{
      'schemaVersion': 1,
      'requestId': requestId,
      'expectedAccountRevision': base.authority.accountRevision,
      'expectedRevision': base.authority.planRevision,
      ...fields,
    };
    final result = WeeklyMealPlanSnapshot.fromJson(
      await _api.request('PUT', _path, token: _token, body: body),
      _context,
    );
    final before = base.authority;
    final after = result.authority;
    if (after.accountId != before.accountId ||
        after.sessionFamilyId != before.sessionFamilyId ||
        after.accountRevision != before.accountRevision ||
        after.planRevision < before.planRevision ||
        after.planRevision > before.planRevision + 1 ||
        result.plan == null ||
        jsonEncode(result.plan!.toFieldsJson()) != jsonEncode(fields)) {
      throw const LarenorServerException('invalid_response');
    }
    return result;
  }
}

/// Captures the exact endpoint, account generation and Core/home binding. A
/// route or account owner may additionally invalidate [isCurrent].
final class WeeklyMealPlanAccountGateway implements WeeklyMealPlanGateway {
  WeeklyMealPlanAccountGateway({
    required this.account,
    required this.context,
    required this.isCurrent,
    ServerApiFactory? apiFactory,
  }) : _generation = account.generation,
       _endpoint = account.session!.endpoint,
       _accountId = account.session!.user.id,
       _api =
           (apiFactory ?? ((endpoint) => LarenorServerApi(endpoint: endpoint)))(
             account.session!.endpoint,
           );

  final ServerAccountController account;
  final ServerContext context;
  final bool Function() isCurrent;
  final int _generation;
  final ServerEndpoint _endpoint;
  final String _accountId;
  final LarenorServerApi _api;
  String? _sessionFamilyId;
  bool _closed = false;

  Future<WeeklyMealPlanApi> _authorized() async {
    if (_closed || !isCurrent() || !account.isCurrent(_generation)) {
      throw const LarenorServerException('cancelled');
    }
    final session = await account.ensureSession();
    if (_closed ||
        !isCurrent() ||
        !account.isCurrent(_generation) ||
        session.context != context ||
        session.endpoint.baseUrl != _endpoint.baseUrl ||
        session.user.id != _accountId) {
      throw const LarenorServerException('cancelled');
    }
    return WeeklyMealPlanApi(_api, session.accessToken, context);
  }

  Future<WeeklyMealPlanSnapshot> _operation(
    Future<WeeklyMealPlanSnapshot> Function(WeeklyMealPlanApi api) action,
  ) async {
    final value = await action(await _authorized());
    await _authorized();
    if (value.authority.accountId != _accountId ||
        _sessionFamilyId != null &&
            value.authority.sessionFamilyId != _sessionFamilyId) {
      throw const LarenorServerException('invalid_response');
    }
    _sessionFamilyId ??= value.authority.sessionFamilyId;
    return value;
  }

  @override
  Future<WeeklyMealPlanSnapshot> read() => _operation((api) => api.read());

  @override
  Future<WeeklyMealPlanSnapshot> save({
    required WeeklyMealPlanSnapshot base,
    required String requestId,
    required String weekStart,
    required List<MealRecipe> recipes,
    required List<MealPlanEntry> entries,
  }) => _operation(
    (api) => api.save(
      base: base,
      requestId: requestId,
      weekStart: weekStart,
      recipes: recipes,
      entries: entries,
    ),
  );

  void close() {
    if (_closed) return;
    _closed = true;
    _api.close();
  }
}
