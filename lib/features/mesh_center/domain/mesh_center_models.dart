import 'package:flutter/foundation.dart';

enum MeshProtocol { zigbee, thread }

enum MeshPowerSource { mains, battery }

enum MeshHealthState { healthy, degraded, unavailable }

enum MeshUpdateStatus { confirmed, uncertain }

@immutable
final class MeshClientAuthority {
  const MeshClientAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.routeId,
    required this.homeRevision,
    required this.accountRevision,
    required this.memberRevision,
    required this.sessionRevision,
    required this.routeRevision,
    required this.admin,
    required this.canUpdate,
  });

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionFamilyId;
  final String routeId;
  final int homeRevision;
  final int accountRevision;
  final int memberRevision;
  final int sessionRevision;
  final int routeRevision;
  final bool admin;
  final bool canUpdate;

  bool get isBounded =>
      coreId.isNotEmpty &&
      homeId.isNotEmpty &&
      accountId.isNotEmpty &&
      sessionFamilyId.isNotEmpty &&
      routeId.isNotEmpty &&
      homeRevision >= 0 &&
      accountRevision >= 0 &&
      memberRevision >= 0 &&
      sessionRevision >= 0 &&
      routeRevision >= 0;

  @override
  bool operator ==(Object other) =>
      other is MeshClientAuthority &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId &&
      routeId == other.routeId &&
      homeRevision == other.homeRevision &&
      accountRevision == other.accountRevision &&
      memberRevision == other.memberRevision &&
      sessionRevision == other.sessionRevision &&
      routeRevision == other.routeRevision &&
      admin == other.admin &&
      canUpdate == other.canUpdate;

  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    sessionFamilyId,
    routeId,
    homeRevision,
    accountRevision,
    memberRevision,
    sessionRevision,
    routeRevision,
    admin,
    canUpdate,
  );

  @override
  String toString() => 'MeshClientAuthority(redacted)';
}

@immutable
final class MeshFirmwareOffer {
  const MeshFirmwareOffer({
    required this.catalogId,
    required this.catalogRevision,
    required this.catalogProviderRevision,
    required this.firmwareId,
    required this.targetVersion,
    required this.firmwareSha256,
    required this.signedMetadataVerified,
    required this.compatible,
    required this.expiresAt,
  });

  final String catalogId;
  final String catalogRevision;
  final String catalogProviderRevision;
  final String firmwareId;
  final String targetVersion;
  final String firmwareSha256;
  final bool signedMetadataVerified;
  final bool compatible;
  final DateTime expiresAt;

  bool isUsableAt(DateTime now) =>
      catalogId.isNotEmpty &&
      catalogRevision.isNotEmpty &&
      catalogProviderRevision.isNotEmpty &&
      firmwareId.isNotEmpty &&
      RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')
          .hasMatch(targetVersion) &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(firmwareSha256) &&
      signedMetadataVerified &&
      compatible &&
      expiresAt.isAfter(now);

  @override
  String toString() => 'MeshFirmwareOffer($firmwareId, digest-redacted)';
}

@immutable
final class MeshClientDevice {
  const MeshClientDevice({
    required this.deviceId,
    required this.name,
    required this.deviceRevision,
    required this.expectedResultRevision,
    required this.providerRevision,
    required this.routeRevision,
    required this.protocol,
    required this.manufacturer,
    required this.model,
    required this.hardwareRevision,
    required this.installedVersion,
    required this.powerSource,
    required this.batteryPercent,
    required this.reachable,
    required this.updating,
    required this.routeDepth,
    required this.lastSeenAt,
    required this.update,
  });

  final String deviceId;
  final String name;
  final String deviceRevision;
  final String expectedResultRevision;
  final String providerRevision;
  final String routeRevision;
  final MeshProtocol protocol;
  final String manufacturer;
  final String model;
  final String hardwareRevision;
  final String installedVersion;
  final MeshPowerSource powerSource;
  final int? batteryPercent;
  final bool reachable;
  final bool updating;
  final int routeDepth;
  final DateTime lastSeenAt;
  final MeshFirmwareOffer? update;

  bool isCoherentAt(DateTime now) {
    final powerValid = powerSource == MeshPowerSource.mains
        ? batteryPercent == null
        : batteryPercent != null &&
              batteryPercent! >= 0 &&
              batteryPercent! <= 100;
    return deviceId.isNotEmpty &&
        name.trim().isNotEmpty &&
        deviceRevision.isNotEmpty &&
        expectedResultRevision.isNotEmpty &&
        providerRevision.isNotEmpty &&
        routeRevision.isNotEmpty &&
        manufacturer.trim().isNotEmpty &&
        model.trim().isNotEmpty &&
        hardwareRevision.isNotEmpty &&
        RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')
            .hasMatch(installedVersion) &&
        powerValid &&
        routeDepth >= 1 &&
        routeDepth <= 32 &&
        !lastSeenAt.isAfter(now);
  }

  bool canOfferUpdateAt(DateTime now) {
    final offer = update;
    final safePower =
        powerSource == MeshPowerSource.mains ||
        (batteryPercent != null && batteryPercent! >= 40);
    return isCoherentAt(now) &&
        protocol == MeshProtocol.zigbee &&
        reachable &&
        !updating &&
        routeDepth <= 16 &&
        safePower &&
        offer != null &&
        offer.isUsableAt(now) &&
        _version(offer.targetVersion) > _version(installedVersion);
  }

  int _version(String value) => value.split('.').fold<int>(0, (result, part) {
    return result * 100000 + int.parse(part);
  });
}

@immutable
final class MeshCenterSnapshot {
  MeshCenterSnapshot({
    required this.authority,
    required this.topologyRevision,
    required this.topologyProviderRevision,
    required this.coordinatorRevision,
    required this.interferenceRevision,
    required this.capturedAt,
    required this.health,
    required this.coordinatorOnline,
    required this.channel,
    required this.recommendedChannel,
    required this.channelUtilizationPercent,
    required this.recommendedUtilizationPercent,
    required this.borderRouterCount,
    required this.offlineBorderRouterCount,
    required List<MeshClientDevice> devices,
  }) : devices = List.unmodifiable(devices);

  final MeshClientAuthority authority;
  final String topologyRevision;
  final String topologyProviderRevision;
  final String coordinatorRevision;
  final String interferenceRevision;
  final DateTime capturedAt;
  final MeshHealthState health;
  final bool coordinatorOnline;
  final int channel;
  final int recommendedChannel;
  final int channelUtilizationPercent;
  final int recommendedUtilizationPercent;
  final int borderRouterCount;
  final int offlineBorderRouterCount;
  final List<MeshClientDevice> devices;

  bool get channelAdviceReadOnly => true;

  bool isCoherentAt(DateTime now) {
    final ids = devices.map((item) => item.deviceId).toSet();
    return authority.isBounded &&
        topologyRevision.isNotEmpty &&
        topologyProviderRevision.isNotEmpty &&
        coordinatorRevision.isNotEmpty &&
        interferenceRevision.isNotEmpty &&
        !capturedAt.isAfter(now) &&
        now.difference(capturedAt) <= const Duration(minutes: 5) &&
        channel >= 11 &&
        channel <= 26 &&
        recommendedChannel >= 11 &&
        recommendedChannel <= 26 &&
        channelUtilizationPercent >= 0 &&
        channelUtilizationPercent <= 100 &&
        recommendedUtilizationPercent >= 0 &&
        recommendedUtilizationPercent <= 100 &&
        borderRouterCount >= 0 &&
        borderRouterCount <= 32 &&
        offlineBorderRouterCount >= 0 &&
        offlineBorderRouterCount <= borderRouterCount &&
        devices.length <= 1024 &&
        ids.length == devices.length &&
        devices.every((item) => item.isCoherentAt(now));
  }

  @override
  String toString() => 'MeshCenterSnapshot($health, ${devices.length} devices)';
}

@immutable
final class MeshFirmwareUpdatePreview {
  const MeshFirmwareUpdatePreview({
    required this.authority,
    required this.requestId,
    required this.topologyRevision,
    required this.topologyProviderRevision,
    required this.coordinatorRevision,
    required this.deviceId,
    required this.expectedDeviceRevision,
    required this.expectedResultRevision,
    required this.expectedProviderRevision,
    required this.expectedRouteRevision,
    required this.catalogId,
    required this.catalogRevision,
    required this.catalogProviderRevision,
    required this.firmwareId,
    required this.firmwareSha256,
    required this.targetVersion,
    required this.expiresAt,
    required this.confirmationProof,
  });

  final MeshClientAuthority authority;
  final String requestId;
  final String topologyRevision;
  final String topologyProviderRevision;
  final String coordinatorRevision;
  final String deviceId;
  final String expectedDeviceRevision;
  final String expectedResultRevision;
  final String expectedProviderRevision;
  final String expectedRouteRevision;
  final String catalogId;
  final String catalogRevision;
  final String catalogProviderRevision;
  final String firmwareId;
  final String firmwareSha256;
  final String targetVersion;
  final DateTime expiresAt;
  final String confirmationProof;

  bool isExactFor(
    MeshClientAuthority expectedAuthority,
    MeshCenterSnapshot snapshot,
    MeshClientDevice device,
    MeshFirmwareOffer offer,
    DateTime now,
  ) =>
      authority == expectedAuthority &&
      snapshot.authority == expectedAuthority &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId) &&
      topologyRevision == snapshot.topologyRevision &&
      topologyProviderRevision == snapshot.topologyProviderRevision &&
      coordinatorRevision == snapshot.coordinatorRevision &&
      deviceId == device.deviceId &&
      expectedDeviceRevision == device.deviceRevision &&
      expectedResultRevision == device.expectedResultRevision &&
      expectedProviderRevision == device.providerRevision &&
      expectedRouteRevision == device.routeRevision &&
      catalogId == offer.catalogId &&
      catalogRevision == offer.catalogRevision &&
      catalogProviderRevision == offer.catalogProviderRevision &&
      firmwareId == offer.firmwareId &&
      firmwareSha256 == offer.firmwareSha256 &&
      targetVersion == offer.targetVersion &&
      expiresAt.isAfter(now) &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(confirmationProof);

  @override
  String toString() => 'MeshFirmwareUpdatePreview($requestId, proof-redacted)';
}

@immutable
final class MeshFirmwareUpdateResult {
  const MeshFirmwareUpdateResult({
    required this.authority,
    required this.requestId,
    required this.deviceId,
    required this.previousDeviceRevision,
    required this.deviceRevision,
    required this.providerRevision,
    required this.routeRevision,
    required this.installedVersion,
    required this.installedSha256,
    required this.status,
    required this.readbackVerified,
  });

  final MeshClientAuthority authority;
  final String requestId;
  final String deviceId;
  final String previousDeviceRevision;
  final String deviceRevision;
  final String providerRevision;
  final String routeRevision;
  final String installedVersion;
  final String installedSha256;
  final MeshUpdateStatus status;
  final bool readbackVerified;

  bool isExactFor(MeshFirmwareUpdatePreview preview) =>
      authority == preview.authority &&
      requestId == preview.requestId &&
      deviceId == preview.deviceId &&
      previousDeviceRevision == preview.expectedDeviceRevision &&
      deviceRevision == preview.expectedResultRevision &&
      providerRevision == preview.expectedProviderRevision &&
      routeRevision == preview.expectedRouteRevision &&
      installedVersion == preview.targetVersion &&
      installedSha256 == preview.firmwareSha256 &&
      status == MeshUpdateStatus.confirmed &&
      readbackVerified;
}
