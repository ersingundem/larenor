import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/data/kiosk_sensor_api.dart';
import 'package:larenor/features/kiosk/data/kiosk_sensor_controller.dart';
import 'package:larenor/features/kiosk/domain/kiosk_sensor_models.dart';

const _session = '123e4567-e89b-12d3-a456-426614174000';

Map<String, Object?> _sample({
  String sessionId = _session,
  int sequence = 1,
  bool sampling = true,
  double? lux = 12,
  double? motionDelta = 0.8,
  String cameraStatus = 'available',
}) => {
  'version': 1,
  'sessionId': sessionId,
  'sequence': sequence,
  'sampling': sampling,
  'lightAvailable': true,
  'motionAvailable': true,
  'observedAtElapsedMillis': 1000,
  'lux': lux,
  'motionDelta': motionDelta,
  'cameraStatus': cameraStatus,
};

final class _Api implements KioskSensorApi {
  Object? startValue = _sample(sequence: 0, lux: null, motionDelta: null);
  Object? readValue = _sample();
  Object? stopValue = {'version': 1, 'sessionId': _session, 'stopped': true};
  int stops = 0;

  @override
  Future<KioskSensorSnapshot> start({required int intervalMillis}) async =>
      KioskSensorSnapshot.fromChannel(startValue);

  @override
  Future<KioskSensorSnapshot> read(String sessionId) async =>
      KioskSensorSnapshot.fromChannel(readValue, expectedSessionId: sessionId);

  @override
  Future<KioskSensorStopReceipt> stop(String sessionId) async {
    stops++;
    return KioskSensorStopReceipt.fromChannel(
      stopValue,
      expectedSessionId: sessionId,
    );
  }
}

void main() {
  test('snapshot is strict, bounded and keeps sensor absence distinct', () {
    final unavailable = _sample(lux: null, motionDelta: null)
      ..['lightAvailable'] = false
      ..['motionAvailable'] = false;
    final value = KioskSensorSnapshot.fromChannel(unavailable);
    expect(value.lightAvailable, isFalse);
    expect(value.motionAvailable, isFalse);
    expect(value.isDark, isNull);
    expect(value.isMoving(KioskSensorSensitivity.medium), isNull);
    expect(value.cameraStatus, KioskSensorCameraStatus.available);

    for (final invalid in [
      {..._sample(), 'secret': 'must-not-be-accepted'},
      {..._sample(), 'sessionId': 'foreign'},
      {..._sample(), 'lux': -1.0},
      {..._sample(), 'motionDelta': double.infinity},
      {..._sample(), 'sequence': -1},
      {..._sample(), 'cameraStatus': 'recording'},
    ]) {
      expect(
        () => KioskSensorSnapshot.fromChannel(invalid),
        throwsA(isA<KioskSensorException>()),
      );
    }
  });

  test(
    'controller rejects foreign/out-of-order reads and verifies stop',
    () async {
      final api = _Api();
      final controller = KioskSensorController(api);
      await controller.start();
      expect((await controller.refresh()).sequence, 1);
      api.readValue = _sample(sequence: 0);
      await expectLater(
        controller.refresh(),
        throwsA(isA<KioskSensorException>()),
      );
      api.readValue = _sample(
        sessionId: '00000000-0000-0000-0000-000000000000',
      );
      await expectLater(
        controller.refresh(),
        throwsA(isA<KioskSensorException>()),
      );
      api.stopValue = {'version': 1, 'sessionId': _session, 'stopped': false};
      await expectLater(
        controller.stop(),
        throwsA(isA<KioskSensorException>()),
      );
      expect(controller.active, isTrue);
      api.stopValue = {'version': 1, 'sessionId': _session, 'stopped': true};
      await controller.stop();
      expect(controller.active, isFalse);
    },
  );

  test(
    'Android channel uses exact bounded requests and redacts failures',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.ersingundem.larenor/kiosk'),
            (call) async {
              calls.add(call);
              return switch (call.method) {
                'sensorStart' => _sample(
                  sequence: 0,
                  lux: null,
                  motionDelta: null,
                ),
                'sensorRead' => _sample(),
                'sensorStop' => {
                  'version': 1,
                  'sessionId': _session,
                  'stopped': true,
                },
                _ => throw MissingPluginException(),
              };
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.ersingundem.larenor/kiosk'),
              null,
            ),
      );
      final api = AndroidKioskSensorApi(isAndroid: true);
      await api.start(intervalMillis: 1000);
      await api.read(_session);
      await api.stop(_session);
      expect(calls.map((e) => e.method), [
        'sensorStart',
        'sensorRead',
        'sensorStop',
      ]);
      expect(calls.first.arguments, {'intervalMillis': 1000});
      expect(calls[1].arguments, {'sessionId': _session});
      expect(calls[2].arguments, {'sessionId': _session});
    },
  );
}
