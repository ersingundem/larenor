import 'package:flutter/foundation.dart';

@immutable
final class EpaperSourceDevice {
  const EpaperSourceDevice({
    required this.serviceId,
    required this.serviceRevision,
    required this.deviceId,
    required this.sourceRevision,
    required this.name,
    required this.width,
    required this.height,
    required this.batteryPercent,
    required this.lastSeenAt,
    required this.reachable,
  });

  final String serviceId, deviceId, name;
  final int serviceRevision, sourceRevision, width, height;
  final int? batteryPercent;
  final DateTime? lastSeenAt;
  final bool reachable;

  factory EpaperSourceDevice.fromJson(Map<String, dynamic> json) =>
      EpaperSourceDevice(
        serviceId: json['serviceId'] as String,
        serviceRevision: json['serviceRevision'] as int,
        deviceId: json['deviceId'] as String,
        sourceRevision: json['sourceRevision'] as int,
        name: json['name'] as String,
        width: json['width'] as int,
        height: json['height'] as int,
        batteryPercent: json['batteryPercent'] as int?,
        lastSeenAt: json['lastSeenAtMs'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                json['lastSeenAtMs'] as int,
                isUtc: true,
              ),
        reachable: json['reachable'] as bool,
      );

  bool get isValid =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(serviceId) &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(deviceId) &&
      serviceRevision > 0 &&
      sourceRevision > 0 &&
      name.isNotEmpty &&
      name.length <= 80 &&
      width >= 64 &&
      width <= 2048 &&
      height >= 32 &&
      height <= 2048;
}

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
    this.connectivity = 'unknown',
    this.capabilityVerified = false,
    this.batteryPercent,
    this.lastSeenAt,
    this.width = 0,
    this.height = 0,
    this.supportedColors = const <String>[],
    this.retainsLastImageOffline = true,
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
  final String connectivity;
  final bool capabilityVerified, retainsLastImageOffline;
  final int? batteryPercent;
  final int width, height;
  final DateTime? lastSeenAt;
  final List<String> supportedColors;

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
        connectivity: json['connectivity'] as String? ?? 'unknown',
        capabilityVerified: json['capabilityVerified'] as bool? ?? false,
        batteryPercent: json['batteryPercent'] as int?,
        lastSeenAt: json['lastSeenAtMs'] is int
            ? DateTime.fromMillisecondsSinceEpoch(
                json['lastSeenAtMs'] as int,
                isUtc: true,
              )
            : null,
        width: json['width'] as int? ?? 0,
        height: json['height'] as int? ?? 0,
        supportedColors: List<String>.unmodifiable(
          (json['supportedColors'] as List? ?? const <Object>[]).cast<String>(),
        ),
        retainsLastImageOffline:
            json['retainsLastImageOffline'] as bool? ?? true,
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
    connectivity: connectivity,
    capabilityVerified: capabilityVerified,
    batteryPercent: batteryPercent,
    lastSeenAt: lastSeenAt,
    width: width,
    height: height,
    supportedColors: supportedColors,
    retainsLastImageOffline: retainsLastImageOffline,
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
    if (!const {'online', 'offline', 'unknown'}.contains(connectivity) ||
        (batteryPercent != null &&
            (batteryPercent! < 0 || batteryPercent! > 100)) ||
        (lastSeenAt != null && lastSeenAt!.isAfter(now)) ||
        width < 0 ||
        width > 2048 ||
        height < 0 ||
        height > 2048 ||
        supportedColors.length > 4 ||
        supportedColors.toSet().length != supportedColors.length) {
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
    this.artifactPath,
    this.artifactDigest,
    this.physicalDeliveryVerified = false,
  });

  final EpaperClientAuthority authority;
  final String requestId;
  final String deviceId;
  final String deviceRevision;
  final EpaperManagementAction action;
  final String expectedLayoutRevision;
  final DateTime expiresAt;
  final String? artifactPath, artifactDigest;
  final bool physicalDeliveryVerified;

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
        artifactPath: json['artifactPath'] as String?,
        artifactDigest: json['artifactDigest'] as String?,
        physicalDeliveryVerified: json['physicalDeliveryVerified'] == true,
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
      expiresAt.isAfter(now) &&
      !physicalDeliveryVerified &&
      (artifactPath == null ||
          RegExp(
            r'^/admin/epaper/[a-f0-9]{32}/[a-f0-9]{32}/previews/[a-f0-9]{32}/artifact$',
          ).hasMatch(artifactPath!)) &&
      (artifactDigest == null ||
          RegExp(r'^[a-f0-9]{64}$').hasMatch(artifactDigest!));

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
    this.serviceId,
    this.serviceRevision,
    this.sourceRevision,
    this.title = 'Larenor',
    this.value = '--:--',
  });

  final String deviceId;
  final String name;
  final int width;
  final int height;
  final String? serviceId;
  final int? serviceRevision, sourceRevision;
  final String title, value;

  factory EpaperDeviceMappingDraft.fromSource(
    EpaperSourceDevice source, {
    required String name,
    required String title,
    required String value,
  }) => EpaperDeviceMappingDraft(
    deviceId: source.deviceId,
    name: name,
    width: source.width,
    height: source.height,
    serviceId: source.serviceId,
    serviceRevision: source.serviceRevision,
    sourceRevision: source.sourceRevision,
    title: title,
    value: value,
  );

  bool get isValid =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(deviceId) &&
      name.trim() == name &&
      name.isNotEmpty &&
      name.length <= 80 &&
      width >= 64 &&
      width <= 2048 &&
      height >= 32 &&
      height <= 2048 &&
      title.trim() == title &&
      title.isNotEmpty &&
      title.length <= 32 &&
      value.trim() == value &&
      value.isNotEmpty &&
      value.length <= 48;

  bool get hasVerifiedSource =>
      serviceId != null &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(serviceId!) &&
      serviceRevision != null &&
      serviceRevision! > 0 &&
      sourceRevision != null &&
      sourceRevision! > 0;
}
