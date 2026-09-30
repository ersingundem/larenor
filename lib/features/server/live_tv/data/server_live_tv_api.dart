import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_live_tv_models.dart';

final class ServerLiveTvApi {
  ServerLiveTvApi(this.api, this.session, {String Function()? requestId})
    : _requestId = requestId ?? _randomId;
  final LarenorServerApi api;
  final ServerSession session;
  final String Function() _requestId;

  Future<ServerLiveTvSnapshot> read({bool Function()? current}) async {
    _current(current);
    final result = _response(
      await api.request('GET', '/media/live-tv', token: session.accessToken),
      {'schemaVersion', 'snapshot'},
    );
    _current(current);
    if (result['schemaVersion'] != 1) _invalidResponse();
    return ServerLiveTvSnapshot.fromJson(result['snapshot'], session);
  }

  Future<ServerLiveTvSourceOptions> sourceOptions({
    bool Function()? current,
  }) async {
    _current(current);
    final result = _response(
      await api.request(
        'GET',
        '/media/live-tv/source-options',
        token: session.accessToken,
      ),
      {'schemaVersion', 'expectedRevision', 'services'},
    );
    _current(current);
    final services = result['services'];
    final expectedRevision = result['expectedRevision'];
    if (result['schemaVersion'] != 1 ||
        expectedRevision is! int ||
        expectedRevision < 0 ||
        expectedRevision > 0x1fffffffffffff ||
        services is! List ||
        services.length > 128) {
      _invalidResponse();
    }
    final parsed = services
        .map(ServerLiveTvSourceOption.fromJson)
        .toList(growable: false);
    if (parsed.map((item) => item.serviceId).toSet().length != parsed.length) {
      _invalidResponse();
    }
    return ServerLiveTvSourceOptions(expectedRevision, parsed);
  }

  Future<ServerLiveTvSnapshot> configureJellyfin({
    required int expectedRevision,
    required ServerLiveTvSourceOption service,
    required String providerKind,
    required String timeZone,
    required int quotaBytes,
    bool Function()? current,
  }) async {
    if (expectedRevision < 0 ||
        expectedRevision > 0x1fffffffffffff ||
        (providerKind != 'tuner' && providerKind != 'iptv') ||
        timeZone.isEmpty ||
        timeZone.length > 64 ||
        timeZone.trim() != timeZone ||
        timeZone.contains(RegExp(r'[\x00-\x20\x7f]')) ||
        quotaBytes < 1073741824 ||
        quotaBytes > 10995116277760) {
      throw const LarenorServerException('invalid_request');
    }
    _current(current);
    final result = _response(
      await api.request(
        'PUT',
        '/media/live-tv/jellyfin-source',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestId': _id(),
          'expectedRevision': expectedRevision,
          'serviceId': service.serviceId,
          'expectedServiceRevision': service.serviceRevision,
          'providerKind': providerKind,
          'timeZone': timeZone,
          'quotaBytes': quotaBytes,
        },
      ),
      {'schemaVersion', 'snapshot'},
    );
    _current(current);
    if (result['schemaVersion'] != 1) _invalidResponse();
    return ServerLiveTvSnapshot.fromJson(result['snapshot'], session);
  }

  Future<void> schedule(
    ServerLiveTvSnapshot snapshot,
    ServerLiveTvProgramme programme, {
    bool Function()? current,
  }) async {
    await _mutate('POST', '/media/live-tv/recordings', {
      'schemaVersion': 1,
      'requestId': _id(),
      'expectedSourceRevision': snapshot.sourceRevision,
      'expectedProviderRevision': snapshot.providerRevision,
      'programmeId': programme.id,
    }, current);
  }

  Future<void> cancel(
    ServerLiveTvRecording recording, {
    bool Function()? current,
  }) => _mutate('POST', '/media/live-tv/recordings/${recording.id}/cancel', {
    'schemaVersion': 1,
    'requestId': _id(),
    'expectedRevision': recording.revision,
  }, current);

  Future<void> restart(
    ServerLiveTvRecording recording, {
    bool Function()? current,
  }) => _mutate('POST', '/media/live-tv/recordings/${recording.id}/restart', {
    'schemaVersion': 1,
    'requestId': _id(),
    'expectedRevision': recording.revision,
  }, current);

  Future<void> _mutate(
    String method,
    String path,
    Map<String, Object?> body,
    bool Function()? current,
  ) async {
    _current(current);
    final result = _response(
      await api.request(method, path, token: session.accessToken, body: body),
      {'schemaVersion', 'recording'},
    );
    _current(current);
    if (result['schemaVersion'] != 1) _invalidResponse();
    ServerLiveTvRecording.fromJson(result['recording']);
  }

  String _id() {
    final value = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  static Map<String, dynamic> _response(Object? raw, Set<String> keys) {
    final value = serverObject(raw);
    if (value.length != keys.length || !value.keys.every(keys.contains)) {
      _invalidResponse();
    }
    return value;
  }

  static Never _invalidResponse() =>
      throw const LarenorServerException('invalid_response');
  static void _current(bool Function()? value) {
    if (value != null && !value()) {
      throw const LarenorServerException('retired');
    }
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
