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
    this.duration = const Duration(seconds: 1),
    this.feedback,
    this.notificationEligible = false,
  });
  final String eventId, roomId, deviceId, className;
  final double confidence;
  final DateTime observedAt, retentionExpiresAt;
  final int eventRevision;
  final bool acknowledged, automationVerified;
  final Duration duration;
  final String? feedback;
  final bool notificationEligible;

  bool coherentAt(DateTime now) =>
      _identity(eventId) &&
      _identity(roomId) &&
      _identity(deviceId) &&
      {'bark', 'noise'}.contains(className) &&
      confidence >= 0 &&
      confidence <= 1 &&
      duration.inMilliseconds >= 100 &&
      duration.inMilliseconds <= 60000 &&
      (feedback == null || {'false_alarm', 'confirmed'}.contains(feedback)) &&
      eventRevision >= 1 &&
      !observedAt.isAfter(now) &&
      retentionExpiresAt.isAfter(now);
}

@immutable
final class SoundEventPolicy {
  const SoundEventPolicy({
    required this.revision,
    required this.notificationsEnabled,
    required this.barkEnabled,
    required this.noiseEnabled,
    required this.mutedUntil,
    required this.sourceClipRetention,
  });

  const SoundEventPolicy.disabled()
    : revision = 1,
      notificationsEnabled = false,
      barkEnabled = true,
      noiseEnabled = true,
      mutedUntil = null,
      sourceClipRetention = 'never';

  final int revision;
  final bool notificationsEnabled, barkEnabled, noiseEnabled;
  final DateTime? mutedUntil;
  final String sourceClipRetention;

  bool get muted => mutedUntil?.isAfter(DateTime.now().toUtc()) ?? false;

  bool coherentAt(DateTime now) =>
      revision >= 1 && sourceClipRetention == 'never';
}

@immutable
final class SoundSourceStatus {
  const SoundSourceStatus({
    required this.state,
    required this.capabilityRevision,
    required this.providerRevision,
    required this.modelRevision,
    required this.lastObservationAt,
    required this.freshnessDeadline,
    required this.silenceProven,
    required this.clipAvailable,
  });

  const SoundSourceStatus.unavailable()
    : state = 'unavailable',
      capabilityRevision = null,
      providerRevision = null,
      modelRevision = null,
      lastObservationAt = null,
      freshnessDeadline = null,
      silenceProven = false,
      clipAvailable = false;

  final String state;
  final int? capabilityRevision, providerRevision, modelRevision;
  final DateTime? lastObservationAt, freshnessDeadline;
  final bool silenceProven, clipAvailable;

  bool get current =>
      state == 'ready' &&
      (freshnessDeadline?.isAfter(DateTime.now().toUtc()) ?? false);

  bool coherentAt(DateTime now) {
    if (silenceProven ||
        !{'ready', 'degraded', 'stale', 'unavailable'}.contains(state)) {
      return false;
    }
    if (state == 'unavailable') {
      return capabilityRevision == null &&
          providerRevision == null &&
          modelRevision == null &&
          lastObservationAt == null &&
          freshnessDeadline == null &&
          !clipAvailable;
    }
    return capabilityRevision != null &&
        capabilityRevision! >= 1 &&
        providerRevision != null &&
        providerRevision! >= 1 &&
        modelRevision != null &&
        modelRevision! >= 1 &&
        freshnessDeadline != null &&
        (lastObservationAt == null || !lastObservationAt!.isAfter(now));
  }
}

@immutable
final class SoundEventSnapshot {
  const SoundEventSnapshot({
    required this.authority,
    required this.repositoryRevision,
    required this.events,
    this.policy = const SoundEventPolicy.disabled(),
    this.sourceStatus = const SoundSourceStatus.unavailable(),
  });
  final SoundEventAuthority authority;
  final int repositoryRevision;
  final List<SoundEventItem> events;
  final SoundEventPolicy policy;
  final SoundSourceStatus sourceStatus;

  bool coherentFor(SoundEventAuthority expected, DateTime now) {
    if (authority != expected ||
        repositoryRevision != authority.repositoryRevision ||
        events.length > 100 ||
        !authority.isBounded ||
        !policy.coherentAt(now) ||
        !sourceStatus.coherentAt(now)) {
      return false;
    }
    final ids = <String>{};
    return events.every(
      (event) => event.coherentAt(now) && ids.add(event.eventId),
    );
  }
}

@immutable
final class SoundEventPolicyReceipt {
  const SoundEventPolicyReceipt({
    required this.requestId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.repositoryRevision,
    required this.policy,
  });
  final String requestId, accountId, sessionFamilyId;
  final int repositoryRevision;
  final SoundEventPolicy policy;

  bool exactFor(SoundEventAuthority authority, SoundEventSnapshot before) =>
      _identity(requestId) &&
      accountId == authority.accountId &&
      sessionFamilyId == authority.sessionFamilyId &&
      repositoryRevision == before.repositoryRevision + 1 &&
      policy.revision == before.policy.revision + 1;
}

@immutable
final class SoundEventFeedbackReceipt {
  const SoundEventFeedbackReceipt({
    required this.requestId,
    required this.eventId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.repositoryRevision,
    required this.eventRevision,
    required this.classification,
  });
  final String requestId, eventId, accountId, sessionFamilyId, classification;
  final int repositoryRevision, eventRevision;

  bool exactFor(
    SoundEventAuthority authority,
    SoundEventSnapshot before,
    SoundEventItem event,
    String expectedClassification,
  ) =>
      _identity(requestId) &&
      eventId == event.eventId &&
      accountId == authority.accountId &&
      sessionFamilyId == authority.sessionFamilyId &&
      repositoryRevision == before.repositoryRevision + 1 &&
      eventRevision == event.eventRevision + 1 &&
      classification == expectedClassification &&
      {'false_alarm', 'confirmed'}.contains(classification);
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
