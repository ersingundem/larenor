import 'package:flutter/foundation.dart';

enum LegacyRemoteProtocol { ir, rf }

enum LegacyRemoteProvider { homeAssistant, isolatedBridge }

enum LegacyRemoteDispatchStatus { dispatched, uncertain }

enum LegacyRemoteCommandKey {
  powerToggle,
  powerOn,
  powerOff,
  volumeUp,
  volumeDown,
  mute,
  channelUp,
  channelDown,
  inputNext,
  menu,
  back,
  up,
  down,
  left,
  right,
  select,
  play,
  pause,
  stop,
}

@immutable
final class LegacyRemoteAuthority {
  const LegacyRemoteAuthority({
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
      other is LegacyRemoteAuthority &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId &&
      routeId == other.routeId &&
      homeRevision == other.homeRevision &&
      accountRevision == other.accountRevision &&
      memberRevision == other.memberRevision &&
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
    memberRevision,
    sessionRevision,
    routeRevision,
  );

  @override
  String toString() => 'LegacyRemoteAuthority(redacted)';
}

@immutable
final class LegacyRemoteCommandDefinition {
  const LegacyRemoteCommandDefinition({
    required this.bindingId,
    required this.key,
    required this.maxRepeats,
    required this.maxHoldMs,
  });
  final String bindingId;
  final LegacyRemoteCommandKey key;
  final int maxRepeats;
  final int maxHoldMs;

  bool get isBounded =>
      bindingId.isNotEmpty &&
      maxRepeats >= 1 &&
      maxRepeats <= 3 &&
      maxHoldMs >= 0 &&
      maxHoldMs <= 2000;

  @override
  String toString() => 'LegacyRemoteCommandDefinition($key, opaque)';
}

/// Secret-free device/profile projection. Raw IR/RF signal bytes, learning
/// payloads, provider credentials, and confirmation proofs are not included.
@immutable
final class LegacyRemoteDevice {
  LegacyRemoteDevice({
    required this.authority,
    required this.deviceId,
    required this.name,
    required this.deviceRevision,
    required this.providerType,
    required this.providerId,
    required this.providerRevision,
    required this.bridgeRevision,
    required this.protocol,
    required this.profileId,
    required this.profileRevision,
    required this.codeSetRevision,
    required this.stored,
    required this.reachable,
    required this.providerVerified,
    required List<LegacyRemoteCommandDefinition> commands,
  }) : commands = List.unmodifiable(commands);

  final LegacyRemoteAuthority authority;
  final String deviceId;
  final String name;
  final String deviceRevision;
  final LegacyRemoteProvider providerType;
  final String providerId;
  final String providerRevision;
  final String bridgeRevision;
  final LegacyRemoteProtocol protocol;
  final String profileId;
  final String profileRevision;
  final String codeSetRevision;
  final bool stored;
  final bool reachable;
  final bool providerVerified;
  final List<LegacyRemoteCommandDefinition> commands;

  bool get canDispatch => stored && reachable && providerVerified;

  bool get isCoherent {
    if (!authority.isBounded ||
        deviceId.isEmpty ||
        name.trim().isEmpty ||
        deviceRevision.isEmpty ||
        providerId.isEmpty ||
        providerRevision.isEmpty ||
        bridgeRevision.isEmpty ||
        profileId.isEmpty ||
        profileRevision.isEmpty ||
        codeSetRevision.isEmpty ||
        commands.isEmpty ||
        commands.length > 64 ||
        commands.any((item) => !item.isBounded)) {
      return false;
    }
    return commands.map((item) => item.key).toSet().length == commands.length &&
        commands.map((item) => item.bindingId).toSet().length ==
            commands.length;
  }

  @override
  String toString() => 'LegacyRemoteDevice($deviceId, secret-free)';
}

@immutable
final class LegacyRemoteCommandPreview {
  const LegacyRemoteCommandPreview({
    required this.authority,
    required this.requestId,
    required this.deviceId,
    required this.deviceRevision,
    required this.providerType,
    required this.providerId,
    required this.providerRevision,
    required this.bridgeRevision,
    required this.protocol,
    required this.profileId,
    required this.profileRevision,
    required this.codeSetRevision,
    required this.bindingId,
    required this.key,
    required this.repeats,
    required this.holdMs,
    required this.expiresAt,
    required this.confirmationProof,
  });

  final LegacyRemoteAuthority authority;
  final String requestId;
  final String deviceId;
  final String deviceRevision;
  final LegacyRemoteProvider providerType;
  final String providerId;
  final String providerRevision;
  final String bridgeRevision;
  final LegacyRemoteProtocol protocol;
  final String profileId;
  final String profileRevision;
  final String codeSetRevision;
  final String bindingId;
  final LegacyRemoteCommandKey key;
  final int repeats;
  final int holdMs;
  final DateTime expiresAt;
  final String confirmationProof;

  bool isExactFor(
    LegacyRemoteAuthority expectedAuthority,
    LegacyRemoteDevice device,
    LegacyRemoteCommandDefinition command,
    DateTime now,
  ) =>
      authority == expectedAuthority &&
      device.authority == expectedAuthority &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId) &&
      deviceId == device.deviceId &&
      deviceRevision == device.deviceRevision &&
      providerType == device.providerType &&
      providerId == device.providerId &&
      providerRevision == device.providerRevision &&
      bridgeRevision == device.bridgeRevision &&
      protocol == device.protocol &&
      profileId == device.profileId &&
      profileRevision == device.profileRevision &&
      codeSetRevision == device.codeSetRevision &&
      bindingId == command.bindingId &&
      key == command.key &&
      repeats >= 1 &&
      repeats <= command.maxRepeats &&
      holdMs >= 0 &&
      holdMs <= command.maxHoldMs &&
      expiresAt.isAfter(now) &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(confirmationProof);

  @override
  String toString() => 'LegacyRemoteCommandPreview($key, redacted)';
}

@immutable
final class LegacyRemoteCommandResult {
  const LegacyRemoteCommandResult({
    required this.authority,
    required this.requestId,
    required this.deviceId,
    required this.deviceRevision,
    required this.providerId,
    required this.providerRevision,
    required this.bridgeRevision,
    required this.profileId,
    required this.profileRevision,
    required this.codeSetRevision,
    required this.bindingId,
    required this.key,
    required this.repeats,
    required this.holdMs,
    required this.status,
    required this.deliveryVerified,
    required this.deviceStateVerified,
  });

  final LegacyRemoteAuthority authority;
  final String requestId;
  final String deviceId;
  final String deviceRevision;
  final String providerId;
  final String providerRevision;
  final String bridgeRevision;
  final String profileId;
  final String profileRevision;
  final String codeSetRevision;
  final String bindingId;
  final LegacyRemoteCommandKey key;
  final int repeats;
  final int holdMs;
  final LegacyRemoteDispatchStatus status;
  final bool deliveryVerified;
  final bool deviceStateVerified;

  bool isExactFor(LegacyRemoteCommandPreview preview) =>
      authority == preview.authority &&
      requestId == preview.requestId &&
      deviceId == preview.deviceId &&
      deviceRevision == preview.deviceRevision &&
      providerId == preview.providerId &&
      providerRevision == preview.providerRevision &&
      bridgeRevision == preview.bridgeRevision &&
      profileId == preview.profileId &&
      profileRevision == preview.profileRevision &&
      codeSetRevision == preview.codeSetRevision &&
      bindingId == preview.bindingId &&
      key == preview.key &&
      repeats == preview.repeats &&
      holdMs == preview.holdMs &&
      status == LegacyRemoteDispatchStatus.dispatched &&
      deliveryVerified &&
      !deviceStateVerified;

  @override
  String toString() => 'LegacyRemoteCommandResult($status, redacted)';
}
