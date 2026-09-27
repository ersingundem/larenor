import 'package:flutter/services.dart';

enum PersonalCameraFailure {
  permissionDenied,
  noFrontCamera,
  cameraBusy,
  batteryCritical,
  thermalCritical,
  unavailable,
}

final class PersonalCameraException implements Exception {
  const PersonalCameraException(this.failure);
  final PersonalCameraFailure failure;
}

final class PersonalCameraSession {
  const PersonalCameraSession({
    required this.id,
    required this.textureId,
    required this.width,
    required this.height,
  });

  final String id;
  final int textureId;
  final int width;
  final int height;
}

final class PersonalCameraEvent {
  const PersonalCameraEvent({required this.sessionId, required this.reason});
  final String sessionId;
  final String reason;
}

abstract interface class PersonalCameraPlatform {
  Stream<PersonalCameraEvent> get events;
  Future<PersonalCameraSession> open();
  Future<void> close(String sessionId);
}

final class MethodChannelPersonalCameraPlatform
    implements PersonalCameraPlatform {
  const MethodChannelPersonalCameraPlatform();

  static const _methods = MethodChannel(
    'com.ersingundem.larenor/personal_camera',
  );
  static const _events = EventChannel(
    'com.ersingundem.larenor/personal_camera_events',
  );

  @override
  Stream<PersonalCameraEvent> get events =>
      _events.receiveBroadcastStream().map(_map).map((value) {
        _exact(value, const {'schemaVersion', 'sessionId', 'state', 'reason'});
        if (_integer(value['schemaVersion']) != 1 ||
            value['state'] != 'closed') {
          throw const FormatException('Invalid personal camera event');
        }
        return PersonalCameraEvent(
          sessionId: _identity(value['sessionId']),
          reason: _identity(value['reason']),
        );
      });

  @override
  Future<PersonalCameraSession> open() async {
    try {
      final value = _map(
        await _methods.invokeMethod<Object>('open', const {'schemaVersion': 1}),
      );
      _exact(value, const {
        'schemaVersion',
        'sessionId',
        'textureId',
        'width',
        'height',
      });
      if (_integer(value['schemaVersion']) != 1) {
        throw const FormatException('Invalid personal camera session');
      }
      final width = _integer(value['width']);
      final height = _integer(value['height']);
      if (width < 1 || height < 1) {
        throw const FormatException('Invalid personal camera dimensions');
      }
      return PersonalCameraSession(
        id: _identity(value['sessionId']),
        textureId: _integer(value['textureId']),
        width: width,
        height: height,
      );
    } on PlatformException catch (error) {
      throw PersonalCameraException(_failure(error.code));
    } on MissingPluginException {
      throw const PersonalCameraException(PersonalCameraFailure.unavailable);
    } on FormatException {
      throw const PersonalCameraException(PersonalCameraFailure.unavailable);
    }
  }

  @override
  Future<void> close(String sessionId) async {
    try {
      final value = _map(
        await _methods.invokeMethod<Object>('close', {
          'schemaVersion': 1,
          'sessionId': sessionId,
        }),
      );
      _exact(value, const {'schemaVersion', 'sessionId', 'closed'});
      if (_integer(value['schemaVersion']) != 1 ||
          _identity(value['sessionId']) != sessionId ||
          value['closed'] is! bool ||
          value['closed'] != true) {
        throw const FormatException('Invalid personal camera close receipt');
      }
    } on PlatformException catch (error) {
      throw PersonalCameraException(_failure(error.code));
    } on MissingPluginException {
      throw const PersonalCameraException(PersonalCameraFailure.unavailable);
    } on FormatException {
      throw const PersonalCameraException(PersonalCameraFailure.unavailable);
    }
  }

  static PersonalCameraFailure _failure(String code) => switch (code) {
    'permissionDenied' => PersonalCameraFailure.permissionDenied,
    'noFrontCamera' => PersonalCameraFailure.noFrontCamera,
    'cameraBusy' => PersonalCameraFailure.cameraBusy,
    'batteryCritical' => PersonalCameraFailure.batteryCritical,
    'thermalCritical' => PersonalCameraFailure.thermalCritical,
    _ => PersonalCameraFailure.unavailable,
  };

  static Map<String, Object?> _map(Object? raw) {
    if (raw is! Map) throw const FormatException('Expected object');
    final result = <String, Object?>{};
    for (final entry in raw.entries) {
      if (entry.key is! String) throw const FormatException('Invalid key');
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static void _exact(Map<String, Object?> value, Set<String> keys) {
    if (value.keys.toSet().length != keys.length ||
        !value.keys.toSet().containsAll(keys)) {
      throw const FormatException('Invalid object shape');
    }
  }

  static int _integer(Object? value) {
    if (value is! int) throw const FormatException('Expected integer');
    return value;
  }

  static String _identity(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 128 ||
        !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) {
      throw const FormatException('Invalid identity');
    }
    return value;
  }
}
