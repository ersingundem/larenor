import 'dart:math';

import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/camera_search_models.dart';
import '../domain/camera_search_source_models.dart';

final class CameraSearchApi
    implements CameraSearchGateway, CameraSearchFeedbackGateway {
  CameraSearchApi(
    LarenorServerApi api,
    ServerSession session, {
    required bool Function() isCurrent,
  }) : this._current(api, session, isCurrent);

  CameraSearchApi._current(this._api, this._session, this._isCurrent);

  final LarenorServerApi _api;
  final ServerSession _session;
  final bool Function() _isCurrent;
  final Map<String, String> _pendingFeedbackIds = {};
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

  Future<CameraSearchSourceState> sources() async {
    _check();
    if (!_session.user.canAdminister) {
      throw const LarenorServerException('forbidden');
    }
    final c = _context;
    final raw = await _api.request(
      'GET',
      '/admin/camera-search/${c.coreId}/${c.homeId}/sources',
      token: _session.accessToken,
    );
    _check();
    return CameraSearchSourceState.decode(serverObject(raw));
  }

  Future<CameraSearchSourceState> configureSources({
    required int revision,
    required CameraSearchSourceChoice service,
    required List<String> cameras,
  }) async {
    _check();
    if (!_session.user.canAdminister) {
      throw const LarenorServerException('forbidden');
    }
    if (service.revision == null ||
        cameras.isEmpty ||
        cameras.length > 16 ||
        cameras.toSet().length != cameras.length ||
        revision < 0) {
      throw const LarenorServerException('invalid_request');
    }
    final c = _context;
    final raw = await _api.request(
      'PUT',
      '/admin/camera-search/${c.coreId}/${c.homeId}/sources',
      token: _session.accessToken,
      body: {
        'schemaVersion': 1,
        'expectedRevision': revision,
        'serviceId': service.id,
        'expectedServiceRevision': service.revision,
        'cameraResourceIds': cameras,
      },
    );
    _check();
    return CameraSearchSourceState.decode(serverObject(raw));
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
  Future<void> reportIncorrect({
    required String query,
    required int expectedIndexRevision,
    required CameraSearchEvidence evidence,
    required CameraSearchFeedbackReason reason,
  }) async {
    _check();
    final context = _context;
    if (evidence.coreId != context.coreId ||
        evidence.homeId != context.homeId ||
        evidence.indexRevision != expectedIndexRevision) {
      throw const LarenorServerException('invalid_request');
    }
    final feedbackKey = [
      query,
      evidence.clipId,
      evidence.captureRevision,
      reason.wireValue,
    ].join(':');
    final requestId = _pendingFeedbackIds.putIfAbsent(feedbackKey, () {
      final random = Random.secure();
      return List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
    });
    final response = serverObject(
      await _api.request(
        'POST',
        '/camera-search/${context.coreId}/${context.homeId}/feedback',
        token: _session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestId': requestId,
          'query': query,
          'expectedIndexRevision': expectedIndexRevision,
          'evidence': {
            'schemaVersion': 1,
            'kind': 'camera_evidence',
            'coreId': evidence.coreId,
            'homeId': evidence.homeId,
            'cameraId': evidence.cameraId,
            'clipId': evidence.clipId,
            'eventId': evidence.eventId,
            'captureRevision': evidence.captureRevision,
            'indexRevision': evidence.indexRevision,
            'capturedAtMs': evidence.capturedAt.toUtc().millisecondsSinceEpoch,
          },
          'reason': reason.wireValue,
        },
      ),
    );
    _check();
    if (response.length != 3 ||
        response['schemaVersion'] != 1 ||
        response['requestId'] != requestId ||
        response['recorded'] != true) {
      throw const LarenorServerException('invalid_response');
    }
    _pendingFeedbackIds.remove(feedbackKey);
  }

  @override
  void retire() {
    _retired = true;
    _pendingFeedbackIds.clear();
  }
}
