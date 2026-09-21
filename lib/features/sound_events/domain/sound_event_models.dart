import 'package:flutter/foundation.dart';

enum SoundEventClassFilter { all, bark, noise }

enum SoundEventStatusFilter { all, unacknowledged, acknowledged }

@immutable
final class SoundEventFilter {
  const SoundEventFilter({
    this.eventClass = SoundEventClassFilter.all,
    this.status = SoundEventStatusFilter.all,
  });
  final SoundEventClassFilter eventClass;
  final SoundEventStatusFilter status;
}

@immutable
final class SoundEventAuthority {
  const SoundEventAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.accountRevision,
    required this.repositoryRevision,
    required this.canRead,
    required this.canAcknowledge,
  });
  final String coreId, homeId, accountId, sessionFamilyId;
  final int accountRevision, repositoryRevision;
  final bool canRead, canAcknowledge;

  bool get isBounded =>
      _identity(coreId) &&
      _identity(homeId) &&
      _identity(accountId) &&
      _identity(sessionFamilyId) &&
      accountRevision >= 1 &&
      repositoryRevision >= 1 &&
      canRead;

  SoundEventAuthority withRepositoryRevision(int value) => SoundEventAuthority(
    coreId: coreId,
    homeId: homeId,
    accountId: accountId,
    sessionFamilyId: sessionFamilyId,
    accountRevision: accountRevision,
    repositoryRevision: value,
    canRead: canRead,
    canAcknowledge: canAcknowledge,
  );

  @override
  bool operator ==(Object other) =>
      other is SoundEventAuthority &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId &&
      accountRevision == other.accountRevision &&
      repositoryRevision == other.repositoryRevision &&
      canRead == other.canRead &&
      canAcknowledge == other.canAcknowledge;
  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    sessionFamilyId,
    accountRevision,
    repositoryRevision,
    canRead,
    canAcknowledge,
  );
  @override
  String toString() => 'SoundEventAuthority(redacted)';
}

@immutable
final class SoundEventItem {
  const SoundEventItem({
    required this.eventId,
    required this.roomId,
    required this.deviceId,
    required this.className,
    required this.confidence,
    required this.observedAt,
    required this.retentionExpiresAt,
    required this.eventRevision,
    required this.acknowledged,
    required this.automationVerified,
  });
  final String eventId, roomId, deviceId, className;
  final double confidence;
  final DateTime observedAt, retentionExpiresAt;
  final int eventRevision;
  final bool acknowledged, automationVerified;

  bool coherentAt(DateTime now) =>
      _identity(eventId) &&
      _identity(roomId) &&
      _identity(deviceId) &&
      className.trim().isNotEmpty &&
      className.length <= 48 &&
      confidence >= 0 &&
      confidence <= 1 &&
      eventRevision >= 1 &&
      !observedAt.isAfter(now) &&
      retentionExpiresAt.isAfter(now);
}

@immutable
final class SoundEventSnapshot {
  const SoundEventSnapshot({
    required this.authority,
    required this.repositoryRevision,
    required this.events,
  });
  final SoundEventAuthority authority;
  final int repositoryRevision;
  final List<SoundEventItem> events;

  bool coherentFor(SoundEventAuthority expected, DateTime now) {
    if (authority != expected ||
        repositoryRevision != authority.repositoryRevision ||
        events.length > 100 ||
        !authority.isBounded) {
      return false;
    }
    final ids = <String>{};
    return events.every(
      (event) => event.coherentAt(now) && ids.add(event.eventId),
    );
  }
}

@immutable
final class SoundEventAcknowledgement {
  const SoundEventAcknowledgement({
    required this.requestId,
    required this.eventId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.repositoryRevision,
    required this.eventRevision,
    required this.acknowledged,
  });
  final String requestId, eventId, accountId, sessionFamilyId;
  final int repositoryRevision, eventRevision;
  final bool acknowledged;

  bool exactFor(
    SoundEventAuthority authority,
    SoundEventSnapshot before,
    SoundEventItem event,
  ) =>
      _identity(requestId) &&
      eventId == event.eventId &&
      accountId == authority.accountId &&
      sessionFamilyId == authority.sessionFamilyId &&
      repositoryRevision == before.repositoryRevision + 1 &&
      eventRevision == event.eventRevision + 1 &&
      acknowledged;
}

bool _identity(String value) => RegExp(r'^[0-9a-f]{32}$').hasMatch(value);
