import 'package:flutter/services.dart';

enum PersonalCameraFailure {
  permissionDenied,
  noFrontCamera,
  cameraBusy,
  batteryCritical,
  thermalCritical,
  profileExists,
  profileStale,
  enrollmentTimeout,
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

final class PersonalCameraCapabilities {
  const PersonalCameraCapabilities({
    required this.platform,
    required this.osApiLevel,
    required this.frontCamera,
    required this.preview,
    required this.detectorArtifact,
    required this.detectorVersion,
    required this.detectorDelivery,
    required this.requiresGooglePlayServices,
    required this.faceDetection,
    required this.identityRecognition,
    required this.termsUrl,
    required this.performanceEvaluation,
  });

  final String platform;
  final int osApiLevel;
  final bool frontCamera;
  final bool preview;
  final String detectorArtifact;
  final String detectorVersion;
  final String detectorDelivery;
  final bool requiresGooglePlayServices;
  final bool faceDetection;
  final bool identityRecognition;
  final Uri termsUrl;
  final String performanceEvaluation;
}

final class PersonalFaceProfile {
  const PersonalFaceProfile({
    required this.id,
    required this.createdAt,
    required this.sampleCount,
    required this.detectorVersion,
  });

  final String id;
  final DateTime createdAt;
  final int sampleCount;
  final String detectorVersion;
}

abstract interface class PersonalCameraPlatform {
  Stream<PersonalCameraEvent> get events;
  Future<PersonalCameraCapabilities> capabilities();
  Future<PersonalFaceProfile?> profile();
  Future<PersonalFaceProfile> enroll(String sessionId);
  Future<void> deleteProfile(String profileId);
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
  Future<PersonalCameraCapabilities> capabilities() async {
    try {
      final value = _map(
        await _methods.invokeMethod<Object>('capabilities', const {
          'schemaVersion': 1,
        }),
      );
      _exact(value, const {
        'schemaVersion',
        'platform',
        'osApiLevel',
        'frontCamera',
        'preview',
        'detectorArtifact',
        'detectorVersion',
        'detectorDelivery',
        'requiresGooglePlayServices',
        'faceDetection',
        'identityRecognition',
        'termsUrl',
        'performanceEvaluation',
      });
      if (_integer(value['schemaVersion']) != 1) {
        throw const FormatException('Invalid personal camera capabilities');
      }
      final termsUrl = Uri.tryParse(_text(value['termsUrl'], 256));
      if (termsUrl == null ||
          termsUrl.scheme != 'https' ||
          termsUrl.host != 'developers.google.com' ||
          termsUrl.path != '/ml-kit/terms') {
        throw const FormatException('Invalid personal camera terms URL');
      }
      return PersonalCameraCapabilities(
        platform: _token(value['platform']),
        osApiLevel: _integer(value['osApiLevel']),
        frontCamera: _boolean(value['frontCamera']),
        preview: _boolean(value['preview']),
        detectorArtifact: _artifact(value['detectorArtifact']),
        detectorVersion: _version(value['detectorVersion']),
        detectorDelivery: _token(value['detectorDelivery']),
        requiresGooglePlayServices: _boolean(
          value['requiresGooglePlayServices'],
        ),
        faceDetection: _boolean(value['faceDetection']),
        identityRecognition: _boolean(value['identityRecognition']),
        termsUrl: termsUrl,
        performanceEvaluation: _token(value['performanceEvaluation']),
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
  Future<PersonalFaceProfile?> profile() async {
    try {
      final value = _map(
        await _methods.invokeMethod<Object>('profile', const {
          'schemaVersion': 1,
        }),
      );
      if (value['exists'] == false) {
        _exact(value, const {'schemaVersion', 'exists'});
        if (_integer(value['schemaVersion']) != 1) {
          throw const FormatException('Invalid personal face profile status');
        }
        return null;
      }
      return _profile(value);
    } on PlatformException catch (error) {
      throw PersonalCameraException(_failure(error.code));
    } on MissingPluginException {
      throw const PersonalCameraException(PersonalCameraFailure.unavailable);
    } on FormatException {
      throw const PersonalCameraException(PersonalCameraFailure.unavailable);
    }
  }

  @override
  Future<PersonalFaceProfile> enroll(String sessionId) async {
    try {
      final value = _map(
        await _methods.invokeMethod<Object>('enroll', {
          'schemaVersion': 1,
          'sessionId': sessionId,
        }),
      );
      return _profile(value);
    } on PlatformException catch (error) {
      throw PersonalCameraException(_failure(error.code));
    } on MissingPluginException {
      throw const PersonalCameraException(PersonalCameraFailure.unavailable);
    } on FormatException {
      throw const PersonalCameraException(PersonalCameraFailure.unavailable);
    }
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    try {
      final value = _map(
        await _methods.invokeMethod<Object>('deleteProfile', {
          'schemaVersion': 1,
          'profileId': profileId,
        }),
      );
      _exact(value, const {'schemaVersion', 'profileId', 'deleted'});
      if (_integer(value['schemaVersion']) != 1 ||
          _identity(value['profileId']) != profileId ||
          value['deleted'] != true) {
        throw const FormatException('Invalid personal face profile deletion');
      }
    } on PlatformException catch (error) {
      throw PersonalCameraException(_failure(error.code));
    } on MissingPluginException {
      throw const PersonalCameraException(PersonalCameraFailure.unavailable);
    } on FormatException {
      throw const PersonalCameraException(PersonalCameraFailure.unavailable);
    }
  }

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
    'profileExists' => PersonalCameraFailure.profileExists,
    'profileStale' => PersonalCameraFailure.profileStale,
    'enrollmentTimeout' => PersonalCameraFailure.enrollmentTimeout,
    _ => PersonalCameraFailure.unavailable,
  };

  static PersonalFaceProfile _profile(Map<String, Object?> value) {
    _exact(value, const {
      'schemaVersion',
      'exists',
      'profileId',
      'createdAtMs',
      'sampleCount',
      'detectorVersion',
    });
    final createdAtMs = _integer(value['createdAtMs']);
    final sampleCount = _integer(value['sampleCount']);
    if (_integer(value['schemaVersion']) != 1 ||
        value['exists'] != true ||
        createdAtMs <= 0 ||
        sampleCount < 5 ||
        sampleCount > 32) {
      throw const FormatException('Invalid personal face profile');
    }
    return PersonalFaceProfile(
      id: _identity(value['profileId']),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true),
      sampleCount: sampleCount,
      detectorVersion: _version(value['detectorVersion']),
    );
  }

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

  static bool _boolean(Object? value) {
    if (value is! bool) throw const FormatException('Expected boolean');
    return value;
  }

  static String _text(Object? value, int maximumLength) {
    if (value is! String || value.isEmpty || value.length > maximumLength) {
      throw const FormatException('Invalid text');
    }
    return value;
  }

  static String _token(Object? value) {
    final text = _text(value, 32);
    if (!RegExp(r'^[a-z][A-Za-z0-9]*$').hasMatch(text)) {
      throw const FormatException('Invalid token');
    }
    return text;
  }

  static String _artifact(Object? value) {
    final text = _text(value, 128);
    if (!RegExp(r'^[a-z0-9.-]+:[a-z0-9.-]+$').hasMatch(text)) {
      throw const FormatException('Invalid artifact');
    }
    return text;
  }

  static String _version(Object? value) {
    final text = _text(value, 32);
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(text)) {
      throw const FormatException('Invalid version');
    }
    return text;
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
