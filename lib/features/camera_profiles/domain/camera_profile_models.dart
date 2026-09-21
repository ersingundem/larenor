import 'package:flutter/foundation.dart';

enum CameraSettingValue { enabled, paused, disabled }

enum CameraApplyState { applied, skipped, failed, unknown }

@immutable
final class CameraProfileAuthority {
  const CameraProfileAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.profileId,
    required this.homeRevision,
    required this.accountRevision,
    required this.profileRevision,
    required this.sessionRevision,
    required this.routeRevision,
    required this.routeId,
    required this.canManage,
  });

  final String coreId, homeId, accountId, sessionFamilyId, profileId, routeId;
  final int homeRevision,
      accountRevision,
      profileRevision,
      sessionRevision,
      routeRevision;
  final bool canManage;

  bool get isBounded =>
      coreId.isNotEmpty &&
      homeId.isNotEmpty &&
      accountId.isNotEmpty &&
      sessionFamilyId.isNotEmpty &&
      profileId.isNotEmpty &&
      routeId.isNotEmpty &&
      homeRevision > 0 &&
      accountRevision > 0 &&
      profileRevision > 0 &&
      sessionRevision >= 0 &&
      routeRevision >= 0 &&
      canManage;

  @override
  bool operator ==(Object other) =>
      other is CameraProfileAuthority &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId &&
      profileId == other.profileId &&
      homeRevision == other.homeRevision &&
      accountRevision == other.accountRevision &&
      profileRevision == other.profileRevision &&
      sessionRevision == other.sessionRevision &&
      routeRevision == other.routeRevision &&
      routeId == other.routeId &&
      canManage == other.canManage;

  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    sessionFamilyId,
    profileId,
    homeRevision,
    accountRevision,
    profileRevision,
    sessionRevision,
    routeRevision,
    routeId,
    canManage,
  );
}

@immutable
final class CameraProfileCamera {
  const CameraProfileCamera({
    required this.id,
    required this.name,
    required this.cameraRevision,
    required this.bindingRevision,
    required this.providerRevision,
    required this.stateRevision,
    required this.recordingSupported,
    required this.detectionSupported,
    required this.currentRecording,
    required this.currentDetection,
    required this.desiredRecording,
    required this.desiredDetection,
  });

  final String id, name;
  final int cameraRevision, bindingRevision, providerRevision, stateRevision;
  final bool recordingSupported, detectionSupported;
  final CameraSettingValue currentRecording, currentDetection;
  final CameraSettingValue desiredRecording, desiredDetection;
}

@immutable
final class CameraProfileSnapshot {
  const CameraProfileSnapshot({
    required this.authority,
    required this.reason,
    required this.cameras,
    required this.microphoneDisabled,
    required this.cameraHardwareDisabled,
    required this.otherRecordersDisabled,
  });

  final CameraProfileAuthority authority;
  final String reason;
  final List<CameraProfileCamera> cameras;
  final bool microphoneDisabled, cameraHardwareDisabled, otherRecordersDisabled;

  bool get hasUnsupported => cameras.any(
    (camera) =>
        (!camera.recordingSupported &&
            camera.currentRecording != camera.desiredRecording) ||
        (!camera.detectionSupported &&
            camera.currentDetection != camera.desiredDetection),
  );

  bool get makesNoHardwarePrivacyClaim =>
      !microphoneDisabled && !cameraHardwareDisabled && !otherRecordersDisabled;
}

@immutable
final class CameraApplyResult {
  const CameraApplyResult({
    required this.cameraId,
    required this.state,
    required this.code,
  });
  final String cameraId, code;
  final CameraApplyState state;
}

@immutable
final class CameraApplyReceipt {
  const CameraApplyReceipt({
    required this.requestId,
    required this.status,
    required this.results,
  });
  final String requestId, status;
  final List<CameraApplyResult> results;
  bool get fullyVerified => status == 'applied' || status == 'already_applied';
}
