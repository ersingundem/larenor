import 'package:flutter/foundation.dart';

@immutable
final class EpaperClientAuthority {
  const EpaperClientAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.homeRevision,
    required this.accountRevision,
    required this.sessionRevision,
    this.canManage = false,
  });

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionFamilyId;
  final int homeRevision;
  final int accountRevision;
  final int sessionRevision;
  final bool canManage;

  factory EpaperClientAuthority.fromJson(Map<String, dynamic> json) =>
      EpaperClientAuthority(
        coreId: json['coreId'] as String,
        homeId: json['homeId'] as String,
        accountId: json['accountId'] as String,
        sessionFamilyId: json['sessionFamilyId'] as String,
        homeRevision: json['homeRevision'] as int,
        accountRevision: json['accountRevision'] as int,
        sessionRevision: json['sessionRevision'] as int,
        canManage: json['canManage'] == true,
      );

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'coreId': coreId,
    'homeId': homeId,
    'accountId': accountId,
    'sessionFamilyId': sessionFamilyId,
    'homeRevision': homeRevision,
    'accountRevision': accountRevision,
    'sessionRevision': sessionRevision,
  };

  bool get isBounded =>
      coreId.isNotEmpty &&
      homeId.isNotEmpty &&
      accountId.isNotEmpty &&
      sessionFamilyId.isNotEmpty &&
      homeRevision > 0 &&
      accountRevision > 0 &&
      sessionRevision > 0;

  @override
  bool operator ==(Object other) =>
      other is EpaperClientAuthority &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId &&
      homeRevision == other.homeRevision &&
      accountRevision == other.accountRevision &&
      sessionRevision == other.sessionRevision &&
      canManage == other.canManage;

  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    sessionFamilyId,
    homeRevision,
    accountRevision,
    sessionRevision,
    canManage,
  );

  @override
  String toString() => 'EpaperClientAuthority(redacted)';
}

enum EpaperSnapshotTrust { empty, pending, partial, acknowledged, stale }

enum EpaperManagementAction { refresh }

enum EpaperCommandStatus { applied, rejected, uncertain }

@immutable
final class EpaperDeviceStatus {
  const EpaperDeviceStatus({
    required this.authority,
    required this.deviceId,
    required this.name,
    required this.deviceRevision,
    required this.bridgeRevision,
    required this.layoutRevision,
    required this.dataRevision,
    required this.policyRevision,
    required this.stored,
    required this.reachable,
    required this.snapshotTrust,
    required this.snapshotDigest,
    required this.verifiedDigest,
    required this.expiresAt,
  });

  final EpaperClientAuthority authority;
  final String deviceId;
  final String name;
  final String deviceRevision;
  final String bridgeRevision;
  final String layoutRevision;
  final String dataRevision;
  final String policyRevision;
  final bool stored;
  final bool reachable;
  final EpaperSnapshotTrust snapshotTrust;
  final String? snapshotDigest;
  final String? verifiedDigest;
  final DateTime expiresAt;

  factory EpaperDeviceStatus.fromJson(Map<String, dynamic> json) =>
      EpaperDeviceStatus(
        authority: EpaperClientAuthority.fromJson(
          json['authority'] as Map<String, dynamic>,
        ),
        deviceId: json['deviceId'] as String,
        name: json['name'] as String,
        deviceRevision: json['deviceRevision'] as String,
        bridgeRevision: json['bridgeRevision'] as String,
        layoutRevision: json['layoutRevision'] as String,
        dataRevision: json['dataRevision'] as String,
        policyRevision: json['policyRevision'] as String,
        stored: json['stored'] as bool,
        reachable: json['reachable'] as bool,
        snapshotTrust: EpaperSnapshotTrust.values.byName(
          json['snapshotTrust'] as String,
        ),
        snapshotDigest: json['snapshotDigest'] as String?,
        verifiedDigest: json['verifiedDigest'] as String?,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          json['expiresAtMs'] as int,
          isUtc: true,
        ),
      );

  EpaperDeviceStatus copyWith({
    String? layoutRevision,
    EpaperSnapshotTrust? snapshotTrust,
    String? snapshotDigest,
    String? verifiedDigest,
  }) => EpaperDeviceStatus(
    authority: authority,
    deviceId: deviceId,
    name: name,
    deviceRevision: deviceRevision,
    bridgeRevision: bridgeRevision,
    layoutRevision: layoutRevision ?? this.layoutRevision,
    dataRevision: dataRevision,
    policyRevision: policyRevision,
    stored: stored,
    reachable: reachable,
    snapshotTrust: snapshotTrust ?? this.snapshotTrust,
    snapshotDigest: snapshotDigest ?? this.snapshotDigest,
    verifiedDigest: verifiedDigest ?? this.verifiedDigest,
    expiresAt: expiresAt,
  );

  bool isCoherentAt(DateTime now) {
    if (authority.isBounded == false ||
        deviceId.isEmpty ||
        name.trim().isEmpty ||
        deviceRevision.isEmpty ||
        bridgeRevision.isEmpty ||
        layoutRevision.isEmpty ||
        dataRevision.isEmpty ||
        policyRevision.isEmpty) {
      return false;
    }
    final digest = RegExp(r'^[a-f0-9]{64}$');
    if (snapshotDigest != null && !digest.hasMatch(snapshotDigest!)) {
      return false;
    }
    if (verifiedDigest != null && !digest.hasMatch(verifiedDigest!)) {
      return false;
    }
    return switch (snapshotTrust) {
      EpaperSnapshotTrust.empty =>
        snapshotDigest == null && verifiedDigest == null,
      EpaperSnapshotTrust.pending ||
      EpaperSnapshotTrust.partial ||
      EpaperSnapshotTrust.acknowledged =>
        snapshotDigest != null && verifiedDigest == null,
      EpaperSnapshotTrust.stale => snapshotDigest != null,
    };
  }

  @override
  String toString() => 'EpaperDeviceStatus($deviceId, $snapshotTrust)';
}

@immutable
final class EpaperCommandPreview {
  const EpaperCommandPreview({
    required this.authority,
    required this.requestId,
    required this.deviceId,
    required this.deviceRevision,
    required this.action,
    required this.expectedLayoutRevision,
    required this.expiresAt,
  });

  final EpaperClientAuthority authority;
  final String requestId;
  final String deviceId;
  final String deviceRevision;
  final EpaperManagementAction action;
  final String expectedLayoutRevision;
  final DateTime expiresAt;

  factory EpaperCommandPreview.fromJson(Map<String, dynamic> json) =>
      EpaperCommandPreview(
        authority: EpaperClientAuthority.fromJson(
          json['authority'] as Map<String, dynamic>,
        ),
        requestId: json['requestId'] as String,
        deviceId: json['deviceId'] as String,
        deviceRevision: json['deviceRevision'] as String,
        action: EpaperManagementAction.values.byName(json['action'] as String),
        expectedLayoutRevision: json['expectedLayoutRevision'] as String,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          json['expiresAtMs'] as int,
          isUtc: true,
        ),
      );

  bool isExactFor(
    EpaperClientAuthority expectedAuthority,
    EpaperDeviceStatus device,
    EpaperManagementAction expectedAction,
    DateTime now,
  ) =>
      authority == expectedAuthority &&
      device.authority == expectedAuthority &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId) &&
      deviceId == device.deviceId &&
      deviceRevision == device.deviceRevision &&
      action == expectedAction &&
      expectedLayoutRevision.isNotEmpty &&
      expiresAt.isAfter(now);

  @override
  String toString() => 'EpaperCommandPreview($action, redacted)';
}

@immutable
final class EpaperCommandReceipt {
  const EpaperCommandReceipt({
    required this.authority,
    required this.requestId,
    required this.deviceId,
    required this.deviceRevision,
    required this.action,
    required this.status,
    required this.observedLayoutRevision,
    required this.observedSnapshotDigest,
  });

  final EpaperClientAuthority authority;
  final String requestId;
  final String deviceId;
  final String deviceRevision;
  final EpaperManagementAction action;
  final EpaperCommandStatus status;
  final String? observedLayoutRevision;
  final String? observedSnapshotDigest;

  factory EpaperCommandReceipt.fromJson(Map<String, dynamic> json) =>
      EpaperCommandReceipt(
        authority: EpaperClientAuthority.fromJson(
          json['authority'] as Map<String, dynamic>,
        ),
        requestId: json['requestId'] as String,
        deviceId: json['deviceId'] as String,
        deviceRevision: json['deviceRevision'] as String,
        action: EpaperManagementAction.values.byName(json['action'] as String),
        status: EpaperCommandStatus.values.byName(json['status'] as String),
        observedLayoutRevision: json['observedLayoutRevision'] as String?,
        observedSnapshotDigest: json['observedSnapshotDigest'] as String?,
      );

  bool isExactFor(EpaperCommandPreview preview) =>
      authority == preview.authority &&
      requestId == preview.requestId &&
      deviceId == preview.deviceId &&
      deviceRevision == preview.deviceRevision &&
      action == preview.action &&
      status == EpaperCommandStatus.applied &&
      observedLayoutRevision == preview.expectedLayoutRevision &&
      observedSnapshotDigest != null &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(observedSnapshotDigest!);

  @override
  String toString() => 'EpaperCommandReceipt($action, $status, redacted)';
}

@immutable
final class EpaperDeviceMappingDraft {
  const EpaperDeviceMappingDraft({
    required this.deviceId,
    required this.name,
    this.width = 800,
    this.height = 480,
  });

  final String deviceId;
  final String name;
  final int width;
  final int height;

  bool get isValid =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(deviceId) &&
      name.trim() == name &&
      name.isNotEmpty &&
      name.length <= 80 &&
      width >= 64 &&
      width <= 2048 &&
      height >= 32 &&
      height <= 2048;
}
