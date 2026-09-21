import 'package:flutter/foundation.dart';

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
  });

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionFamilyId;
  final String routeId;
  final int homeRevision;
  final int accountRevision;
  final int sessionRevision;
  final int routeRevision;

  bool get isBounded =>
      coreId.isNotEmpty &&
      homeId.isNotEmpty &&
      accountId.isNotEmpty &&
      sessionFamilyId.isNotEmpty &&
      routeId.isNotEmpty &&
      homeRevision >= 0 &&
      accountRevision >= 0 &&
      sessionRevision >= 0 &&
      routeRevision >= 0;

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
      routeRevision == other.routeRevision;

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
