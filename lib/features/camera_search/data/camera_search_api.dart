import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/camera_search_models.dart';

final class CameraSearchApi implements CameraSearchGateway {
  CameraSearchApi(
    LarenorServerApi api,
    ServerSession session, {
    required bool Function() isCurrent,
  }) : this._current(api, session, isCurrent);

  CameraSearchApi._current(this._api, this._session, this._isCurrent);

  final LarenorServerApi _api;
  final ServerSession _session;
  final bool Function() _isCurrent;
  bool _retired = false;

  ServerContext get _context => _session.context!;

  void _check() {
    try {
      if (!_retired && _session.context != null && _isCurrent()) return;
    } catch (_) {}
    _retired = true;
    throw const LarenorServerException('cancelled');
  }

  Future<CameraSearchContext> loadContext() async {
    _check();
    final context = _context;
    final response = await _api.request(
      'GET',
      '/camera-search/${context.coreId}/${context.homeId}/context',
      token: _session.accessToken,
    );
    _check();
    return CameraSearchContext.fromJson(response, context);
  }

  @override
  Future<CameraSearchPage> search({
    required String query,
    required CameraSearchFilter filter,
    String? cursor,
  }) async {
    _check();
    final trimmed = query.trim();
    if (trimmed.length < 2 ||
        trimmed.length > 200 ||
        trimmed.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw const LarenorServerException('invalid_request');
    }
    final context = _context;
    final response = await _api.request(
      'POST',
      '/camera-search/${context.coreId}/${context.homeId}/search',
      token: _session.accessToken,
      body: {
        'schemaVersion': 1,
        'query': trimmed,
        'expectedIndexRevision': filter.expectedIndexRevision,
        'startMs': filter.start.toUtc().millisecondsSinceEpoch,
        'endMs': filter.end.toUtc().millisecondsSinceEpoch,
        'cameraIds': filter.cameraIds,
        'pageSize': 30,
        'cursor': cursor,
      },
    );
    _check();
    return CameraSearchPage.fromJson(response, context);
  }

  @override
  void retire() => _retired = true;
}
