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
  });

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionFamilyId;
  final int homeRevision;
  final int accountRevision;
  final int sessionRevision;

  bool get isBounded =>
      coreId.isNotEmpty &&
      homeId.isNotEmpty &&
      accountId.isNotEmpty &&
      sessionFamilyId.isNotEmpty &&
      homeRevision >= 0 &&
      accountRevision >= 0 &&
      sessionRevision >= 0;

  @override
  bool operator ==(Object other) =>
      other is EpaperClientAuthority &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId &&
      homeRevision == other.homeRevision &&
      accountRevision == other.accountRevision &&
      sessionRevision == other.sessionRevision;

  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    sessionFamilyId,
    homeRevision,
    accountRevision,
    sessionRevision,
  );

  @override
  String toString() => 'EpaperClientAuthority(redacted)';
}

enum EpaperSnapshotTrust { empty, pending, partial, verified, stale }

enum EpaperManagementAction { refresh, rotate }

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
      EpaperSnapshotTrust.pending || EpaperSnapshotTrust.partial =>
        snapshotDigest != null && verifiedDigest == null,
      EpaperSnapshotTrust.verified =>
        snapshotDigest != null &&
            snapshotDigest == verifiedDigest &&
            expiresAt.isAfter(now),
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
