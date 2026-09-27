enum EventShareAccessMode { oneTime, timeBound }

enum EventShareMask { face, licensePlate }

enum EventShareMetadata { deviceSerial, gps, cameraName, networkAddress }

class EventShareAuthority {
  const EventShareAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionId,
    required this.cameraId,
    required this.eventId,
    required this.coreRevision,
    required this.homeRevision,
    required this.accountRevision,
    required this.membersRevision,
    required this.cameraRevision,
    required this.eventRevision,
    required this.sessionRevision,
    required this.shareRevision,
    required this.canShare,
  });

  final String coreId, homeId, accountId, sessionId, cameraId, eventId;
  final int coreRevision, homeRevision, accountRevision, membersRevision;
  final int cameraRevision, eventRevision, sessionRevision, shareRevision;
  final bool canShare;
}

class EventShareDraft {
  const EventShareDraft._({
    required this.consentId,
    required this.consentRevision,
    required this.recipientId,
    required this.purpose,
    required this.ttlSeconds,
    required this.accessMode,
    required this.masks,
    required this.removedMetadata,
  });

  static EventShareDraft? tryCreate({
    required String consentId,
    required int consentRevision,
    required String recipientId,
    required String purpose,
    required int ttlSeconds,
    required EventShareAccessMode accessMode,
    required Set<EventShareMask> masks,
    required Set<EventShareMetadata> removedMetadata,
  }) {
    final cleanConsent = consentId.trim();
    final cleanRecipient = recipientId.trim();
    final cleanPurpose = purpose.trim();
    if (!_shareId(cleanConsent) ||
        consentRevision < 1 ||
        !_shareId(cleanRecipient) ||
        cleanPurpose.isEmpty ||
        cleanPurpose.length > 200 ||
        ttlSeconds < 60 ||
        ttlSeconds > 604800 ||
        masks.isEmpty ||
        removedMetadata.isEmpty) {
      return null;
    }
    return EventShareDraft._(
      consentId: cleanConsent,
      consentRevision: consentRevision,
      recipientId: cleanRecipient,
      purpose: cleanPurpose,
      ttlSeconds: ttlSeconds,
      accessMode: accessMode,
      masks: Set.unmodifiable(masks),
      removedMetadata: Set.unmodifiable(removedMetadata),
    );
  }

  final String recipientId;
  final String consentId;
  final int consentRevision;
  final String purpose;
  final int ttlSeconds;
  final EventShareAccessMode accessMode;
  final Set<EventShareMask> masks;
  final Set<EventShareMetadata> removedMetadata;
}

class EventRedactionPreview {
  const EventRedactionPreview({
    required this.previewId,
    required this.sourceDigest,
    required this.outputDigest,
    required this.outputArtifactId,
    required this.pipelineId,
    required this.pipelineRevision,
    required this.proof,
    required this.masks,
    required this.removedMetadata,
    required this.expiresAt,
  });

  final String previewId;
  final String sourceDigest;
  final String outputDigest;
  final String outputArtifactId;
  final String pipelineId;
  final int pipelineRevision;
  final String proof;
  final Set<EventShareMask> masks;
  final Set<EventShareMetadata> removedMetadata;
  final DateTime expiresAt;

  bool covers(EventShareDraft draft) =>
      expiresAt.isAfter(DateTime.now().toUtc()) &&
      masks.containsAll(draft.masks) &&
      removedMetadata.containsAll(draft.removedMetadata) &&
      sourceDigest != outputDigest;
}

class PrivateEventShareRecord {
  const PrivateEventShareRecord({
    required this.id,
    required this.recipientId,
    required this.purpose,
    required this.accessMode,
    required this.expiresAt,
    required this.outputDigest,
    required this.revoked,
    required this.consumed,
  });

  final String id;
  final String recipientId;
  final String purpose;
  final EventShareAccessMode accessMode;
  final DateTime expiresAt;
  final String outputDigest;
  final bool revoked;
  final bool consumed;

  bool get active => !revoked && expiresAt.isAfter(DateTime.now().toUtc());
}

class CreatedPrivateEventShare {
  const CreatedPrivateEventShare({
    required this.record,
    required this.accessToken,
  });

  final PrivateEventShareRecord record;

  /// One-time presentation secret. The server never includes it in snapshots.
  final String accessToken;
}

class EventShareAuditEntry {
  const EventShareAuditEntry({
    required this.auditId,
    required this.action,
    required this.actorId,
    required this.recipientId,
    required this.shareId,
    required this.revision,
    required this.occurredAt,
  });

  final String auditId;
  final String action;
  final String actorId;
  final String recipientId;
  final String shareId;
  final int revision;
  final DateTime occurredAt;
}

class EventShareSnapshot {
  EventShareSnapshot({
    required this.revision,
    required List<PrivateEventShareRecord> shares,
    required List<EventShareAuditEntry> audit,
    required this.auditTruncated,
  }) : shares = List.unmodifiable(shares),
       audit = List.unmodifiable(audit);

  final int revision;
  final List<PrivateEventShareRecord> shares;
  final List<EventShareAuditEntry> audit;
  final bool auditTruncated;
}

class EventShareDownload {
  const EventShareDownload({
    required this.shareId,
    required this.fileName,
    required this.digest,
    required this.bytes,
  });

  final String shareId;
  final String fileName;
  final String digest;
  final List<int> bytes;
}

bool _shareId(String value) =>
    value.isNotEmpty &&
    value.length <= 128 &&
    RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(value);
