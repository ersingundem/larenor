import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/kiosk_sensor_models.dart';

abstract interface class KioskSensorApi {
  Future<KioskSensorSnapshot> start({required int intervalMillis});
  Future<KioskSensorSnapshot> read(String sessionId);
  Future<KioskSensorStopReceipt> stop(String sessionId);
}

final class AndroidKioskSensorApi implements KioskSensorApi {
  AndroidKioskSensorApi({MethodChannel? channel, bool? isAndroid})
    : _channel =
          channel ?? const MethodChannel('com.ersingundem.larenor/kiosk'),
      _android =
          isAndroid ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  final MethodChannel _channel;
  final bool _android;

  Future<Object?> _call(String method, Object args) async {
    if (!_android) {
      throw const KioskSensorException(KioskSensorFailure.unsupported);
    }
    try {
      return await _channel
          .invokeMethod<Object?>(method, args)
          .timeout(const Duration(seconds: 5));
    } on MissingPluginException {
      throw const KioskSensorException(KioskSensorFailure.unsupported);
    } on TimeoutException {
      throw const KioskSensorException(KioskSensorFailure.unavailable);
    } on PlatformException catch (error) {
      throw KioskSensorException(switch (error.code) {
        'denied' => KioskSensorFailure.denied,
        'expired' => KioskSensorFailure.expired,
        'busy' => KioskSensorFailure.busy,
        _ => KioskSensorFailure.unavailable,
      });
    }
  }

  @override
  Future<KioskSensorSnapshot> start({required int intervalMillis}) async =>
      KioskSensorSnapshot.fromChannel(
        await _call('sensorStart', {'intervalMillis': intervalMillis}),
      );

  @override
  Future<KioskSensorSnapshot> read(String sessionId) async =>
      KioskSensorSnapshot.fromChannel(
        await _call('sensorRead', {'sessionId': sessionId}),
        expectedSessionId: sessionId,
      );

  @override
  Future<KioskSensorStopReceipt> stop(String sessionId) async =>
      KioskSensorStopReceipt.fromChannel(
        await _call('sensorStop', {'sessionId': sessionId}),
        expectedSessionId: sessionId,
      );
}
