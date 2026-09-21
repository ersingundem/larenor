import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/room_presence/data/room_presence_management_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const account = '33333333333333333333333333333333';
const family = '44444444444444444444444444444444';
const route = '55555555555555555555555555555555';
const device = '66666666666666666666666666666666';
const room = '99999999999999999999999999999999';
const tag = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, dynamic> authority() => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'accountId': account,
  'sessionFamilyId': family,
  'routeId': route,
  'homeRevision': 5,
  'accountRevision': 8,
  'clientSessionRevision': 3,
  'routeRevision': 2,
  'bindingTag': tag,
};

Map<String, dynamic> evidence({int calibration = 1}) => {
  'schemaVersion': 1,
  'authority': authority(),
  'deviceId': device,
  'deviceName': 'Owner tablet',
  'deviceRevision': 9,
  'modelRevision': 4,
  'policyRevision': 7,
  'consentRevision': 11,
  'consentActive': true,
  'configuredRoomId': room,
  'configuredRoomName': 'Living room',
  'configuredRoomRevision': 13,
  'detectedRoomId': room,
  'detectedRoomRevision': 13,
  'estimateRevision': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'transitionRevision': 1,
  'calibrationRevision': calibration,
  'state': 'present',
  'confidencePermille': 880,
  'sampleCount': 2,
  'observedAtMs': DateTime.utc(2026, 9, 21, 10).millisecondsSinceEpoch,
  'stored': true,
  'providerReachable': true,
  'advisoryOnly': true,
  'grantsAccess': false,
};

Map<String, dynamic> preview() => {
  'schemaVersion': 1,
  'authority': authority(),
  'requestId': 'cccccccccccccccccccccccccccccccc',
  'deviceId': device,
  'deviceRevision': 9,
  'modelRevision': 4,
  'roomId': room,
  'roomRevision': 13,
  'policyRevision': 7,
  'consentRevision': 11,
  'previousCalibrationRevision': 1,
  'nextCalibrationRevision': 2,
  'expiresAtMs': DateTime.utc(2030).millisecondsSinceEpoch,
};

http.Response response(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

CoreRoomPresenceHttpApi api(MockClient client, bool Function() current) =>
    CoreRoomPresenceHttpApi(
      api: LarenorServerApi(
        endpoint: ServerEndpoint('https://synthetic.invalid'),
        client: client,
      ),
      token: 'synthetic_token',
      context: ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': core,
        'homeId': home,
      }),
      accountId: account,
      routeId: route,
      sessionRevision: 3,
      routeRevision: 2,
      isCurrent: current,
    );

void main() {
  test('scope and device list keep the exact signed route authority', () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['schemaVersion'], 1);
      if (request.url.path.endsWith('/scope')) {
        expect(body['routeId'], route);
        return response(authority());
      }
      expect(body['authority'], authority());
      return response({
        'schemaVersion': 1,
        'authority': authority(),
        'devices': [evidence()],
      });
    });
    final value = api(client, () => true);
    final scope = await value.bootstrap();
    final devices = await value.list(scope);
    expect(devices.single.confidencePermille, 880);
    expect(devices.single.observedAt, DateTime.utc(2026, 9, 21, 10));
    expect(devices.single.toString(), isNot(contains('synthetic_token')));
    expect(paths, [
      '/api/v1/room-presence/$core/$home/scope',
      '/api/v1/room-presence/$core/$home/devices/query',
    ]);
  });

  test('preview confirm and readback require exact receipt chain', () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path.endsWith('/scope')) return response(authority());
      if (request.url.path.endsWith('/preview')) return response(preview());
      if (request.url.path.endsWith('/confirm')) {
        return response(
          {...preview(), 'observedCalibrationRevision': 2, 'status': 'applied'}
            ..remove('nextCalibrationRevision')
            ..remove('expiresAtMs'),
        );
      }
      return response(evidence(calibration: 2));
    });
    final value = api(client, () => true);
    final scope = await value.bootstrap();
    final staged = await value.previewCalibration(
      scope,
      deviceId: device,
      expectedDeviceRevision: '9',
      expectedModelRevision: '4',
      roomId: room,
      expectedRoomRevision: '13',
      expectedPolicyRevision: '7',
      expectedConsentRevision: '11',
      expectedCalibrationRevision: '1',
    );
    final receipt = await value.confirmCalibration(scope, staged);
    final readback = await value.readback(scope, deviceId: device);
    expect(receipt.isExactFor(staged), isTrue);
    expect(readback.calibrationRevision, '2');
    expect(
      paths.last,
      '/api/v1/room-presence/$core/$home/devices/$device/readback',
    );
  });

  test('late or foreign authority responses fail closed', () async {
    var current = true;
    final pending = Completer<http.Response>();
    final value = api(MockClient((_) => pending.future), () => current);
    final operation = value.bootstrap();
    await Future<void>.delayed(Duration.zero);
    current = false;
    pending.complete(response(authority()));
    await expectLater(
      operation,
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );

    final foreign = api(
      MockClient((_) async => response({...authority(), 'routeRevision': 3})),
      () => true,
    );
    await expectLater(
      foreign.bootstrap(),
      throwsA(isA<LarenorServerException>()),
    );
  });
}
