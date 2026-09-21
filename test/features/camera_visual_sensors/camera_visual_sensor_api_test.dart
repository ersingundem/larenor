import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/camera_visual_sensors/data/camera_visual_sensor_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final core = 'a' * 32;
final home = 'b' * 32;
final account = 'c' * 32;

ServerSession _session() => ServerSession(
  endpoint: ServerEndpoint('https://core.invalid'),
  accessToken: 'x' * 43,
  refreshToken: 'y' * 43,
  expiresAt: DateTime.utc(2026, 10),
  context: ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
  }),
  user: ServerUser(
    id: account,
    username: 'admin',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
);

Map<String, Object?> _response({String? coreId}) => {
  'schemaVersion': 1,
  'scope': {'schemaVersion': 1, 'coreId': coreId ?? core, 'homeId': home},
  'capability': {
    'schemaVersion': 1,
    'architecture': 'amd64',
    'avx': 'supported',
    'avx2': 'unsupported',
    'arm64': false,
    'detectorState': 'unavailable',
    'trainingSupported': false,
    'inferenceSupported': false,
    'reason': 'cpu_requirements_unmet',
  },
  'rules': [
    {
      'schemaVersion': 1,
      'ruleId': 'd' * 32,
      'ruleRevision': 2,
      'cameraId': 'e' * 32,
      'pipelineId': 'f' * 32,
      'pipelineRevision': 3,
      'modelId': '1' * 32,
      'modelRevision': 4,
      'label': 'Person',
      'state': 'unknown',
      'status': 'unavailable',
      'reason': 'no_trusted_frame',
      'confidenceBps': 0,
      'count': 0,
      'automationEligible': false,
      'accessControlEligible': false,
    },
  ],
};

http.Response _json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'authenticated adapter accepts only exact unavailable projection',
    () async {
      late http.Request request;
      final transport = LarenorServerApi(
        endpoint: _session().endpoint,
        client: MockClient((value) async {
          request = value;
          return _json(_response());
        }),
      );
      addTearDown(transport.close);
      final api = CameraVisualSensorApi(
        transport,
        _session(),
        isCurrent: () => true,
      );
      final value = await api.load();

      expect(request.method, 'GET');
      expect(request.headers['authorization'], 'Bearer ${'x' * 43}');
      expect(
        request.url.path,
        endsWith('/camera-visual-sensors/$core/$home/summary'),
      );
      expect(value.sensors.single.label, 'Person');
      expect(value.sensors.single.ruleRevision, 2);
      expect(value.capability.avx.name, 'supported');
      expect(value.capability.avx2.name, 'unsupported');
    },
  );

  test('foreign scope and forged ready capability fail closed', () async {
    for (final body in [
      _response(coreId: '9' * 32),
      {
        ..._response(),
        'capability': {
          ...(_response()['capability']! as Map<String, Object?>),
          'detectorState': 'ready',
          'inferenceSupported': true,
        },
      },
      {
        ..._response(),
        'rules': [
          {
            ...((_response()['rules']! as List).single as Map<String, Object?>),
            'accessControlEligible': true,
          },
        ],
      },
      {
        ..._response(),
        'capability': {
          ...(_response()['capability']! as Map<String, Object?>),
          'architecture': 'arm64',
          'arm64': true,
          'reason': 'arm64_unverified',
        },
      },
      {
        ..._response(),
        'rules': [
          {
            ...((_response()['rules']! as List).single as Map<String, Object?>),
            'label': 'Person\u202e',
          },
        ],
      },
    ]) {
      final transport = LarenorServerApi(
        endpoint: _session().endpoint,
        client: MockClient((_) async => _json(body)),
      );
      addTearDown(transport.close);
      final api = CameraVisualSensorApi(
        transport,
        _session(),
        isCurrent: () => true,
      );
      await expectLater(api.load(), throwsA(isA<LarenorServerException>()));
    }
  });

  test('late response is rejected after route authority changes', () async {
    var current = true;
    final pending = Completer<http.Response>();
    final transport = LarenorServerApi(
      endpoint: _session().endpoint,
      client: MockClient((_) => pending.future),
    );
    addTearDown(transport.close);
    final api = CameraVisualSensorApi(
      transport,
      _session(),
      isCurrent: () => current,
    );
    final future = api.load();
    await Future<void>.delayed(Duration.zero);
    current = false;
    pending.complete(_json(_response()));
    await expectLater(
      future,
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
  });
}
