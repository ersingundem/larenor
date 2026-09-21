import 'package:flutter/foundation.dart';

final _identityPattern = RegExp(r'^[0-9a-f]{32}$');
final _digestPattern = RegExp(r'^[0-9a-f]{64}$');

Map<String, dynamic> _object(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !raw.keys.every(keys.contains)) {
    throw const FormatException('invalid room presence response');
  }
  return raw.cast<String, dynamic>();
}

String _identity(Object? raw) {
  if (raw is! String || !_identityPattern.hasMatch(raw)) {
    throw const FormatException('invalid room presence identity');
  }
  return raw;
}

String _revision(Object? raw) {
  if (raw is! int || raw < 1 || raw > 9223372036854775807) {
    throw const FormatException('invalid room presence revision');
  }
  return '$raw';
}

int _positiveRevision(Object? raw) {
  if (raw is! int || raw < 1 || raw > 9223372036854775807) {
    throw const FormatException('invalid room presence revision');
  }
  return raw;
}

String _label(Object? raw) {
  if (raw is! String ||
      raw.trim().isEmpty ||
      raw.length > 80 ||
      raw.codeUnits.any((value) => value < 32 || value == 127)) {
    throw const FormatException('invalid room presence label');
  }
  return raw.trim();
}

@immutable
final class RoomPresenceClientAuthority {
  const RoomPresenceClientAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.routeId,
    required this.homeRevision,
    required this.accountRevision,
    required this.sessionRevision,
    required this.routeRevision,
    this.bindingTag =
        '0000000000000000000000000000000000000000000000000000000000000000',
  });

  factory RoomPresenceClientAuthority.fromJson(
    Object? raw, {
    required String coreId,
    required String homeId,
    required String accountId,
    required String routeId,
    required int sessionRevision,
    required int routeRevision,
  }) {
    final value = _object(raw, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'sessionFamilyId',
      'routeId',
      'homeRevision',
      'accountRevision',
      'clientSessionRevision',
      'routeRevision',
      'bindingTag',
    });
    final tag = value['bindingTag'];
    if (value['schemaVersion'] != 1 ||
        tag is! String ||
        !_digestPattern.hasMatch(tag)) {
      throw const FormatException('invalid room presence authority');
    }
    final result = RoomPresenceClientAuthority(
      coreId: _identity(value['coreId']),
      homeId: _identity(value['homeId']),
      accountId: _identity(value['accountId']),
      sessionFamilyId: _identity(value['sessionFamilyId']),
      routeId: _identity(value['routeId']),
      homeRevision: _positiveRevision(value['homeRevision']),
      accountRevision: _positiveRevision(value['accountRevision']),
      sessionRevision: _positiveRevision(value['clientSessionRevision']),
      routeRevision: _positiveRevision(value['routeRevision']),
      bindingTag: tag,
    );
    if (result.coreId != coreId ||
        result.homeId != homeId ||
        result.accountId != accountId ||
        result.routeId != routeId ||
        result.sessionRevision != sessionRevision ||
        result.routeRevision != routeRevision) {
      throw const FormatException('foreign room presence authority');
    }
    return result;
  }

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionFamilyId;
  final String routeId;
  final int homeRevision;
  final int accountRevision;
  final int sessionRevision;
  final int routeRevision;
  final String bindingTag;

  bool get isBounded =>
      _identityPattern.hasMatch(coreId) &&
      _identityPattern.hasMatch(homeId) &&
      _identityPattern.hasMatch(accountId) &&
      _identityPattern.hasMatch(sessionFamilyId) &&
      _identityPattern.hasMatch(routeId) &&
      _digestPattern.hasMatch(bindingTag) &&
      homeRevision >= 1 &&
      accountRevision >= 1 &&
      sessionRevision >= 1 &&
      routeRevision >= 1;

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'coreId': coreId,
    'homeId': homeId,
    'accountId': accountId,
    'sessionFamilyId': sessionFamilyId,
    'routeId': routeId,
    'homeRevision': homeRevision,
    'accountRevision': accountRevision,
    'clientSessionRevision': sessionRevision,
    'routeRevision': routeRevision,
    'bindingTag': bindingTag,
  };

  @override
  bool operator ==(Object other) =>
      other is RoomPresenceClientAuthority &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId &&
      routeId == other.routeId &&
      homeRevision == other.homeRevision &&
      accountRevision == other.accountRevision &&
      sessionRevision == other.sessionRevision &&
      routeRevision == other.routeRevision &&
      bindingTag == other.bindingTag;

  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    sessionFamilyId,
    routeId,
    homeRevision,
    accountRevision,
    sessionRevision,
    routeRevision,
    bindingTag,
  );

  @override
  String toString() => 'RoomPresenceClientAuthority(redacted)';
}

enum PresenceEvidenceState { unknown, candidate, uncertain, present }

enum PresenceCalibrationStatus { applied, rejected, uncertain }

/// Secret-free projection of Core evidence. Raw BLE/UWB identifiers and
/// per-observation history have no place in this public Client model.
@immutable
final class RoomPresenceEvidence {
  const RoomPresenceEvidence({
    required this.authority,
    required this.deviceId,
    required this.deviceName,
    required this.deviceRevision,
    required this.modelRevision,
    required this.policyRevision,
    required this.consentRevision,
    required this.consentActive,
    required this.configuredRoomId,
    required this.configuredRoomName,
    required this.configuredRoomRevision,
    required this.detectedRoomId,
    required this.detectedRoomRevision,
    required this.estimateRevision,
    required this.transitionRevision,
    required this.calibrationRevision,
    required this.state,
    required this.confidencePermille,
    required this.sampleCount,
    required this.observedAt,
    required this.stored,
    required this.providerReachable,
  });

  factory RoomPresenceEvidence.fromJson(
    Object? raw,
    RoomPresenceClientAuthority authority,
  ) {
    final value = _object(raw, const {
      'schemaVersion',
      'authority',
      'deviceId',
      'deviceName',
      'deviceRevision',
      'modelRevision',
      'policyRevision',
      'consentRevision',
      'consentActive',
      'configuredRoomId',
      'configuredRoomName',
      'configuredRoomRevision',
      'detectedRoomId',
      'detectedRoomRevision',
      'estimateRevision',
      'transitionRevision',
      'calibrationRevision',
      'state',
      'confidencePermille',
      'sampleCount',
      'observedAtMs',
      'stored',
      'providerReachable',
      'advisoryOnly',
      'grantsAccess',
    });
    if (value['schemaVersion'] != 1 ||
        value['authority'] is! Map ||
        !mapEquals(
          (value['authority'] as Map).cast<String, dynamic>(),
          authority.toJson(),
        ) ||
        value['consentActive'] is! bool ||
        value['stored'] != true ||
        value['providerReachable'] is! bool ||
        value['advisoryOnly'] != true ||
        value['grantsAccess'] != false) {
      throw const FormatException('invalid room presence evidence');
    }
    final state = switch (value['state']) {
      'unknown' => PresenceEvidenceState.unknown,
      'candidate' => PresenceEvidenceState.candidate,
      'uncertain' => PresenceEvidenceState.uncertain,
      'present' => PresenceEvidenceState.present,
      _ => throw const FormatException('invalid room presence state'),
    };
    final confidence = value['confidencePermille'];
    final samples = value['sampleCount'];
    final transition = value['transitionRevision'];
    final observed = value['observedAtMs'];
    if (confidence is! int ||
        confidence < 0 ||
        confidence > 1000 ||
        samples is! int ||
        samples < 0 ||
        samples > 64 ||
        transition is! int ||
        transition < 0 ||
        observed is! int ||
        observed < 0) {
      throw const FormatException('invalid room presence metrics');
    }
    final detectedId = value['detectedRoomId'];
    final detectedRevision = value['detectedRoomRevision'];
    final result = RoomPresenceEvidence(
      authority: authority,
      deviceId: _identity(value['deviceId']),
      deviceName: _label(value['deviceName']),
      deviceRevision: _revision(value['deviceRevision']),
      modelRevision: _revision(value['modelRevision']),
      policyRevision: _revision(value['policyRevision']),
      consentRevision: _revision(value['consentRevision']),
      consentActive: value['consentActive'] as bool,
      configuredRoomId: _identity(value['configuredRoomId']),
      configuredRoomName: _label(value['configuredRoomName']),
      configuredRoomRevision: _revision(value['configuredRoomRevision']),
      detectedRoomId: detectedId == null ? null : _identity(detectedId),
      detectedRoomRevision: detectedRevision == null
          ? null
          : _revision(detectedRevision),
      estimateRevision: _identity(value['estimateRevision']),
      transitionRevision: transition,
      calibrationRevision: _revision(value['calibrationRevision']),
      state: state,
      confidencePermille: confidence,
      sampleCount: samples,
      observedAt: DateTime.fromMillisecondsSinceEpoch(observed, isUtc: true),
      stored: true,
      providerReachable: value['providerReachable'] as bool,
    );
    return result;
  }

  final RoomPresenceClientAuthority authority;
  final String deviceId;
  final String deviceName;
  final String deviceRevision;
  final String modelRevision;
  final String policyRevision;
  final String consentRevision;
  final bool consentActive;
  final String configuredRoomId;
  final String configuredRoomName;
  final String configuredRoomRevision;
  final String? detectedRoomId;
  final String? detectedRoomRevision;
  final String estimateRevision;
  final int transitionRevision;
  final String calibrationRevision;
  final PresenceEvidenceState state;
  final int confidencePermille;
  final int sampleCount;
  final DateTime observedAt;
  final bool stored;
  final bool providerReachable;

  bool get advisoryOnly => true;
  bool get grantsAccess => false;

  RoomPresenceEvidence copyWith({String? calibrationRevision}) =>
      RoomPresenceEvidence(
        authority: authority,
        deviceId: deviceId,
        deviceName: deviceName,
        deviceRevision: deviceRevision,
        modelRevision: modelRevision,
        policyRevision: policyRevision,
        consentRevision: consentRevision,
        consentActive: consentActive,
        configuredRoomId: configuredRoomId,
        configuredRoomName: configuredRoomName,
        configuredRoomRevision: configuredRoomRevision,
        detectedRoomId: detectedRoomId,
        detectedRoomRevision: detectedRoomRevision,
        estimateRevision: estimateRevision,
        transitionRevision: transitionRevision,
        calibrationRevision: calibrationRevision ?? this.calibrationRevision,
        state: state,
        confidencePermille: confidencePermille,
        sampleCount: sampleCount,
        observedAt: observedAt,
        stored: stored,
        providerReachable: providerReachable,
      );

  bool isCoherentAt(DateTime now) {
    if (!authority.isBounded ||
        deviceId.isEmpty ||
        deviceName.trim().isEmpty ||
        deviceRevision.isEmpty ||
        modelRevision.isEmpty ||
        policyRevision.isEmpty ||
        consentRevision.isEmpty ||
        configuredRoomId.isEmpty ||
        configuredRoomName.trim().isEmpty ||
        configuredRoomRevision.isEmpty ||
        estimateRevision.isEmpty ||
        calibrationRevision.isEmpty ||
        transitionRevision < 0 ||
        confidencePermille < 0 ||
        confidencePermille > 1000 ||
        sampleCount < 0 ||
        sampleCount > 64 ||
        observedAt.isAfter(now.add(const Duration(minutes: 5)))) {
      return false;
    }
    final detected = detectedRoomId != null && detectedRoomRevision != null;
    if ((detectedRoomId == null) != (detectedRoomRevision == null)) {
      return false;
    }
    return switch (state) {
      PresenceEvidenceState.unknown =>
        !detected && confidencePermille == 0 && sampleCount == 0,
      PresenceEvidenceState.candidate => !detected && sampleCount > 0,
      PresenceEvidenceState.uncertain ||
      PresenceEvidenceState.present => detected && sampleCount > 0,
    };
  }

  @override
  String toString() => 'RoomPresenceEvidence($deviceId, $state, private)';
}

@immutable
final class PresenceCalibrationPreview {
  const PresenceCalibrationPreview({
    required this.authority,
    required this.requestId,
    required this.deviceId,
    required this.deviceRevision,
    required this.modelRevision,
    required this.roomId,
    required this.roomRevision,
    required this.policyRevision,
    required this.consentRevision,
    required this.previousCalibrationRevision,
    required this.nextCalibrationRevision,
    required this.expiresAt,
  });

  factory PresenceCalibrationPreview.fromJson(
    Object? raw,
    RoomPresenceClientAuthority authority,
  ) {
    final value = _object(raw, const {
      'schemaVersion',
      'authority',
      'requestId',
      'deviceId',
      'deviceRevision',
      'modelRevision',
      'roomId',
      'roomRevision',
      'policyRevision',
      'consentRevision',
      'previousCalibrationRevision',
      'nextCalibrationRevision',
      'expiresAtMs',
    });
    final expires = value['expiresAtMs'];
    if (value['schemaVersion'] != 1 ||
        value['authority'] is! Map ||
        !mapEquals(
          (value['authority'] as Map).cast<String, dynamic>(),
          authority.toJson(),
        ) ||
        expires is! int ||
        expires < 0) {
      throw const FormatException('invalid calibration preview');
    }
    return PresenceCalibrationPreview(
      authority: authority,
      requestId: _identity(value['requestId']),
      deviceId: _identity(value['deviceId']),
      deviceRevision: _revision(value['deviceRevision']),
      modelRevision: _revision(value['modelRevision']),
      roomId: _identity(value['roomId']),
      roomRevision: _revision(value['roomRevision']),
      policyRevision: _revision(value['policyRevision']),
      consentRevision: _revision(value['consentRevision']),
      previousCalibrationRevision: _revision(
        value['previousCalibrationRevision'],
      ),
      nextCalibrationRevision: _revision(value['nextCalibrationRevision']),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true),
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'authority': authority.toJson(),
    'requestId': requestId,
    'deviceId': deviceId,
    'deviceRevision': int.parse(deviceRevision),
    'modelRevision': int.parse(modelRevision),
    'roomId': roomId,
    'roomRevision': int.parse(roomRevision),
    'policyRevision': int.parse(policyRevision),
    'consentRevision': int.parse(consentRevision),
    'previousCalibrationRevision': int.parse(previousCalibrationRevision),
    'nextCalibrationRevision': int.parse(nextCalibrationRevision),
    'expiresAtMs': expiresAt.millisecondsSinceEpoch,
  };

  final RoomPresenceClientAuthority authority;
  final String requestId;
  final String deviceId;
  final String deviceRevision;
  final String modelRevision;
  final String roomId;
  final String roomRevision;
  final String policyRevision;
  final String consentRevision;
  final String previousCalibrationRevision;
  final String nextCalibrationRevision;
  final DateTime expiresAt;

  bool isExactFor(
    RoomPresenceClientAuthority expectedAuthority,
    RoomPresenceEvidence evidence,
    DateTime now,
  ) =>
      authority == expectedAuthority &&
      evidence.authority == expectedAuthority &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId) &&
      deviceId == evidence.deviceId &&
      deviceRevision == evidence.deviceRevision &&
      modelRevision == evidence.modelRevision &&
      roomId == evidence.configuredRoomId &&
      roomRevision == evidence.configuredRoomRevision &&
      policyRevision == evidence.policyRevision &&
      consentRevision == evidence.consentRevision &&
      previousCalibrationRevision == evidence.calibrationRevision &&
      nextCalibrationRevision.isNotEmpty &&
      nextCalibrationRevision != previousCalibrationRevision &&
      expiresAt.isAfter(now);

  @override
  String toString() => 'PresenceCalibrationPreview(redacted)';
}

@immutable
final class PresenceCalibrationReceipt {
  const PresenceCalibrationReceipt({
    required this.authority,
    required this.requestId,
    required this.deviceId,
    required this.deviceRevision,
    required this.modelRevision,
    required this.roomId,
    required this.roomRevision,
    required this.policyRevision,
    required this.consentRevision,
    required this.previousCalibrationRevision,
    required this.observedCalibrationRevision,
    required this.status,
  });

  factory PresenceCalibrationReceipt.fromJson(
    Object? raw,
    RoomPresenceClientAuthority authority,
  ) {
    final value = _object(raw, const {
      'schemaVersion',
      'authority',
      'requestId',
      'deviceId',
      'deviceRevision',
      'modelRevision',
      'roomId',
      'roomRevision',
      'policyRevision',
      'consentRevision',
      'previousCalibrationRevision',
      'observedCalibrationRevision',
      'status',
    });
    if (value['schemaVersion'] != 1 ||
        value['authority'] is! Map ||
        !mapEquals(
          (value['authority'] as Map).cast<String, dynamic>(),
          authority.toJson(),
        )) {
      throw const FormatException('invalid calibration receipt');
    }
    final status = switch (value['status']) {
      'applied' => PresenceCalibrationStatus.applied,
      'rejected' => PresenceCalibrationStatus.rejected,
      'uncertain' => PresenceCalibrationStatus.uncertain,
      _ => throw const FormatException('invalid calibration status'),
    };
    final observed = value['observedCalibrationRevision'];
    return PresenceCalibrationReceipt(
      authority: authority,
      requestId: _identity(value['requestId']),
      deviceId: _identity(value['deviceId']),
      deviceRevision: _revision(value['deviceRevision']),
      modelRevision: _revision(value['modelRevision']),
      roomId: _identity(value['roomId']),
      roomRevision: _revision(value['roomRevision']),
      policyRevision: _revision(value['policyRevision']),
      consentRevision: _revision(value['consentRevision']),
      previousCalibrationRevision: _revision(
        value['previousCalibrationRevision'],
      ),
      observedCalibrationRevision: observed == null
          ? null
          : _revision(observed),
      status: status,
    );
  }

  final RoomPresenceClientAuthority authority;
  final String requestId;
  final String deviceId;
  final String deviceRevision;
  final String modelRevision;
  final String roomId;
  final String roomRevision;
  final String policyRevision;
  final String consentRevision;
  final String previousCalibrationRevision;
  final String? observedCalibrationRevision;
  final PresenceCalibrationStatus status;

  bool isExactFor(PresenceCalibrationPreview preview) =>
      authority == preview.authority &&
      requestId == preview.requestId &&
      deviceId == preview.deviceId &&
      deviceRevision == preview.deviceRevision &&
      modelRevision == preview.modelRevision &&
      roomId == preview.roomId &&
      roomRevision == preview.roomRevision &&
      policyRevision == preview.policyRevision &&
      consentRevision == preview.consentRevision &&
      previousCalibrationRevision == preview.previousCalibrationRevision &&
      observedCalibrationRevision == preview.nextCalibrationRevision &&
      status == PresenceCalibrationStatus.applied;

  @override
  String toString() => 'PresenceCalibrationReceipt($status, redacted)';
}
