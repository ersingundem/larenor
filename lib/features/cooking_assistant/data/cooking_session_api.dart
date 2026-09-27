import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/cooking_session.dart';
import 'cooking_session_controller.dart';

final class CookingSessionAccountApi implements CookingSessionLifecycleGateway {
  CookingSessionAccountApi({required this.account, required this.isCurrent})
    : _generation = account.generation;

  final ServerAccountController account;
  final bool Function() isCurrent;
  final int _generation;
  bool _closed = false;

  Future<Map<String, dynamic>?> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (_closed || !isCurrent() || !account.isCurrent(_generation)) {
      throw const LarenorServerException('cancelled');
    }
    final result = await account.withSession((api, session) {
      if (!isCurrent()) throw const LarenorServerException('cancelled');
      return api.request(method, path, token: session.accessToken, body: body);
    });
    if (_closed || !isCurrent() || !account.isCurrent(_generation)) {
      throw const LarenorServerException('cancelled');
    }
    return result;
  }

  Future<CookingSession> create({
    required String recipeId,
    required int recipeRevision,
    required String title,
    required List<String> steps,
  }) async => CookingSession.fromResponse(
    await _request(
      'POST',
      '/cooking/sessions',
      body: {
        'schemaVersion': 1,
        'recipeId': recipeId,
        'recipeRevision': recipeRevision,
        'title': title,
        'steps': steps,
      },
    ),
  );

  Future<List<CookingSession>> list() async => CookingSession.listFromResponse(
    await _request('GET', '/cooking/sessions'),
  );

  Future<CookingSession> get(String sessionId) async =>
      CookingSession.fromResponse(
        await _request('GET', '/cooking/sessions/$sessionId'),
      );

  @override
  Future<CookingSession> move({
    required String sessionId,
    required int expectedRevision,
    required int step,
  }) async => CookingSession.fromResponse(
    await _request(
      'PUT',
      '/cooking/sessions/$sessionId/step',
      body: {
        'schemaVersion': 1,
        'expectedRevision': expectedRevision,
        'step': step,
      },
    ),
  );

  @override
  Future<CookingSession> cancel({
    required String sessionId,
    required int expectedRevision,
  }) async => CookingSession.fromResponse(
    await _request(
      'POST',
      '/cooking/sessions/$sessionId/cancel',
      body: {'schemaVersion': 1, 'expectedRevision': expectedRevision},
    ),
  );

  void close() => _closed = true;
}
