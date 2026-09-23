enum KioskSensorSensitivity { low, medium, high }

enum KioskSensorCameraStatus { available, busy, permissionDenied, unavailable }

enum KioskSensorFailure { unsupported, unavailable, denied, expired, busy }

const _snapshotKeys = <String>{
  'version',
  'sessionId',
  'sequence',
  'sampling',
  'lightAvailable',
  'motionAvailable',
  'approachAvailable',
  'observedAtElapsedMillis',
  'lux',
  'motionDelta',
  'approachDistanceCm',
  'approachMaxRangeCm',
  'cameraStatus',
};

final class KioskSensorException implements Exception {
  const KioskSensorException(this.failure);
  final KioskSensorFailure failure;
  @override
  String toString() => 'Local sensor session unavailable';
}

final class KioskSensorSnapshot {
  const KioskSensorSnapshot({
    required this.sessionId,
    required this.sequence,
    required this.sampling,
    required this.lightAvailable,
    required this.motionAvailable,
    required this.approachAvailable,
    required this.observedAtElapsedMillis,
    required this.lux,
    required this.motionDelta,
    required this.approachDistanceCm,
    required this.approachMaxRangeCm,
    required this.cameraStatus,
  });

  final String sessionId;
  final int sequence, observedAtElapsedMillis;
  final bool sampling, lightAvailable, motionAvailable, approachAvailable;
  final double? lux, motionDelta, approachDistanceCm, approachMaxRangeCm;
  final KioskSensorCameraStatus cameraStatus;

  bool? get isDark => !lightAvailable || lux == null ? null : lux! < 20;
  bool? isMoving(KioskSensorSensitivity sensitivity) {
    if (!motionAvailable || motionDelta == null) return null;
    final threshold = switch (sensitivity) {
      KioskSensorSensitivity.low => 1.5,
      KioskSensorSensitivity.medium => .75,
      KioskSensorSensitivity.high => .3,
    };
    return motionDelta! >= threshold;
  }

  bool? get isApproached =>
      !approachAvailable ||
          approachDistanceCm == null ||
          approachMaxRangeCm == null
      ? null
      : approachDistanceCm! < approachMaxRangeCm!;

  factory KioskSensorSnapshot.fromChannel(
    Object? raw, {
    String? expectedSessionId,
  }) {
    Never invalid() =>
        throw const KioskSensorException(KioskSensorFailure.unavailable);
    if (raw is! Map ||
        raw.length != _snapshotKeys.length ||
        !_snapshotKeys.every(raw.containsKey) ||
        raw['version'] != 2 ||
        raw['sessionId'] is! String ||
        raw['sequence'] is! int ||
        raw['sampling'] is! bool ||
        raw['lightAvailable'] is! bool ||
        raw['motionAvailable'] is! bool ||
        raw['approachAvailable'] is! bool ||
        raw['observedAtElapsedMillis'] is! int ||
        !(raw['lux'] == null || raw['lux'] is num) ||
        !(raw['motionDelta'] == null || raw['motionDelta'] is num) ||
        !(raw['approachDistanceCm'] == null ||
            raw['approachDistanceCm'] is num) ||
        !(raw['approachMaxRangeCm'] == null ||
            raw['approachMaxRangeCm'] is num) ||
        raw['cameraStatus'] is! String) {
      invalid();
    }
    final sessionId = raw['sessionId'] as String;
    final sequence = raw['sequence'] as int;
    final observed = raw['observedAtElapsedMillis'] as int;
    final lux = (raw['lux'] as num?)?.toDouble();
    final motion = (raw['motionDelta'] as num?)?.toDouble();
    final approachDistance = (raw['approachDistanceCm'] as num?)?.toDouble();
    final approachMaxRange = (raw['approachMaxRangeCm'] as num?)?.toDouble();
    final camera = KioskSensorCameraStatus.values
        .where((value) => value.name == raw['cameraStatus'])
        .firstOrNull;
    if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(sessionId) ||
        (expectedSessionId != null && sessionId != expectedSessionId) ||
        sequence < 0 ||
        observed < 0 ||
        camera == null ||
        (lux != null && (!lux.isFinite || lux < 0 || lux > 200000)) ||
        (motion != null && (!motion.isFinite || motion < 0 || motion > 100)) ||
        (approachMaxRange != null &&
            (!approachMaxRange.isFinite ||
                approachMaxRange < .1 ||
                approachMaxRange > 100)) ||
        (approachDistance != null &&
            (!approachDistance.isFinite ||
                approachDistance < 0 ||
                approachMaxRange == null ||
                approachDistance > approachMaxRange)) ||
        (raw['lightAvailable'] == false && lux != null) ||
        (raw['motionAvailable'] == false && motion != null) ||
        (raw['approachAvailable'] == false &&
            (approachDistance != null || approachMaxRange != null)) ||
        (raw['approachAvailable'] == true && approachMaxRange == null)) {
      invalid();
    }
    return KioskSensorSnapshot(
      sessionId: sessionId,
      sequence: sequence,
      sampling: raw['sampling'] as bool,
      lightAvailable: raw['lightAvailable'] as bool,
      motionAvailable: raw['motionAvailable'] as bool,
      approachAvailable: raw['approachAvailable'] as bool,
      observedAtElapsedMillis: observed,
      lux: lux,
      motionDelta: motion,
      approachDistanceCm: approachDistance,
      approachMaxRangeCm: approachMaxRange,
      cameraStatus: camera,
    );
  }
}

final class KioskSensorStopReceipt {
  const KioskSensorStopReceipt({
    required this.sessionId,
    required this.stopped,
  });
  final String sessionId;
  final bool stopped;

  factory KioskSensorStopReceipt.fromChannel(
    Object? raw, {
    required String expectedSessionId,
  }) {
    if (raw is! Map ||
        raw.length != 3 ||
        raw['version'] != 1 ||
        raw['sessionId'] != expectedSessionId ||
        raw['stopped'] is! bool) {
      throw const KioskSensorException(KioskSensorFailure.unavailable);
    }
    return KioskSensorStopReceipt(
      sessionId: expectedSessionId,
      stopped: raw['stopped'] as bool,
    );
  }
}
