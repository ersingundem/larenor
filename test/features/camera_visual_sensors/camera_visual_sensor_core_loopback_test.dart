import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/camera_visual_sensors/data/camera_visual_sensor_api.dart';
import 'package:larenor/features/camera_visual_sensors/domain/camera_visual_sensor_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _core = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _home = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _account = 'cccccccccccccccccccccccccccccccc';
const _rule = 'dddddddddddddddddddddddddddddddd';
const _camera = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _pipeline = 'ffffffffffffffffffffffffffffffff';
const _model = '11111111111111111111111111111111';
const _token = 'visual_sensor_loopback_access_token_123456';

final class _VisualCore {
  _VisualCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  String frameState = 'ready';
  bool corruptDigest = false;
  Completer<void>? entered, barrier;
  int calls = 0;

  String get baseUrl => 'http://127.0.0.1:${server.port}';
  static Future<_VisualCore> start() async =>
      _VisualCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> _serve() async {
    await for (final request in server) {
      unawaited(_handle(request).catchError((Object _) {}));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $_token') {
      return _json(request, {
        'error': {'code': 'unauthorized'},
      }, 401);
    }
    if (request.method != 'GET' ||
        request.uri.path !=
            '/api/v1/camera-visual-sensors/$_core/$_home/summary') {
      return _json(request, {
        'error': {'code': 'not_found'},
      }, 404);
    }
    calls++;
    entered?.complete();
    await barrier?.future;
    return _json(request, _summary());
  }

  Map<String, dynamic> _summary() {
    final ready = frameState == 'ready';
    return {
      'schemaVersion': 2,
      'scope': {'schemaVersion': 1, 'coreId': _core, 'homeId': _home},
      'capability': {
        'schemaVersion': 1,
        'architecture': 'amd64',
        'avx': 'supported',
        'avx2': 'supported',
        'arm64': false,
        'detectorState': ready ? 'ready' : 'degraded',
        'trainingSupported': false,
        'inferenceSupported': true,
        'reason': ready ? 'ready' : 'worker_stale',
      },
      'rules': [
        {
          'schemaVersion': 2,
          'ruleId': _rule,
          'ruleRevision': 2,
          'cameraId': _camera,
          'pipelineId': _pipeline,
          'pipelineRevision': 3,
          'modelId': _model,
          'modelRevision': 4,
          'label': 'Person',
          'state': ready ? 'on' : 'unknown',
          'status': ready ? 'ready' : 'degraded',
          'reason': ready ? 'trusted_frame' : 'corrupt_frame',
          'observedAtMs': 1000,
          'staleAtMs': 61000,
          'evidenceDigest': corruptDigest ? 'bad' : '2' * 64,
          'confidenceBps': ready ? 9300 : 0,
          'count': ready ? 1 : 0,
          'automationEligible': ready,
          'accessControlEligible': false,
        },
      ],
    };
  }

  Future<void> close() => server.close(force: true);
}

void _json(HttpRequest request, Object body, [int status = 200]) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  unawaited(request.response.close());
}

ServerSession _session(String baseUrl) => ServerSession(
  endpoint: ServerEndpoint(baseUrl),
  accessToken: _token,
  refreshToken: 'visual_sensor_loopback_refresh_token_12345',
  expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  context: ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': _core,
    'homeId': _home,
  }),
  user: const ServerUser(
    id: _account,
    username: 'admin',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
);

Matcher _code(String value) => throwsA(
  isA<LarenorServerException>().having((error) => error.code, 'code', value),
);

void main() {
  setUpAll(() => HttpOverrides.global = null);

  test('production client accepts trusted worker evidence and degrades corrupt frames over loopback Core', () async {
    final core = await _VisualCore.start();
    addTearDown(core.close);
    final transport = LarenorServerApi(endpoint: ServerEndpoint(core.baseUrl));
    addTearDown(transport.close);
    final api = CameraVisualSensorApi(
      transport,
      _session(core.baseUrl),
      isCurrent: () => true,
    );

    final ready = await api.load();
    expect(ready.capability.detectorState, VisualDetectorState.ready);
    expect(ready.sensors.single.state, VisualSensorState.on);
    expect(ready.sensors.single.automationEligible, isTrue);

    core.frameState = 'corrupt';
    final degraded = await api.load();
    expect(degraded.capability.detectorState, VisualDetectorState.degraded);
    expect(degraded.sensors.single.state, VisualSensorState.unknown);
    expect(degraded.sensors.single.reason, 'corrupt_frame');
    expect(degraded.sensors.single.automationEligible, isFalse);

    core.corruptDigest = true;
    await expectLater(api.load(), _code('invalid_response'));
    expect(core.calls, 3);
  });

  test('late worker summary is discarded after authority retirement', () async {
    final core = await _VisualCore.start();
    addTearDown(core.close);
    final transport = LarenorServerApi(endpoint: ServerEndpoint(core.baseUrl));
    addTearDown(transport.close);
    var current = true;
    core.entered = Completer<void>();
    core.barrier = Completer<void>();
    final api = CameraVisualSensorApi(
      transport,
      _session(core.baseUrl),
      isCurrent: () => current,
    );

    final pending = api.load();
    await core.entered!.future;
    current = false;
    core.barrier!.complete();
    await expectLater(pending, _code('cancelled'));
  });
}
