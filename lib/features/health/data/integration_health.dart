enum IntegrationId {
  ha,
  jellyfin,
  jellyseerr,
  sonarr,
  radarr,
  lidarr,
  readarr,
  bazarr,
  prowlarr,
  qbittorrent,
  keenetic,
  proxmox,
}

enum HealthFailure {
  authentication,
  permission,
  transport,
  timeout,
  server,
  invalidResponse,
}

enum HealthStatus {
  notConfigured,
  configured,
  connecting,
  reachable,
  healthy,
  stale,
  retrying,
  offline,
  authenticationRequired,
  permissionDenied,
  error,
}

/// In-memory evidence about a connection, never inferred from saved tokens or
/// an entity's last_updated timestamp. Successful reads belong to the bound
/// integration's data scope; they do not prove every server API is supported.
class IntegrationHealth {
  const IntegrationHealth({
    this.configured = false,
    this.connecting = false,
    this.lastContact,
    this.lastSuccessfulRead,
    this.lastFailureAt,
    this.failure,
    this.retryAttempt = 0,
    this.liveUpdates = false,
    this.liveSnapshotSynchronized = false,
    this.lastLiveContact,
    this.readFreshness = const Duration(minutes: 2),
    this.liveFreshness = const Duration(seconds: 75),
  });

  final bool configured;
  final bool connecting;
  final DateTime? lastContact;
  final DateTime? lastSuccessfulRead;
  final DateTime? lastFailureAt;
  final HealthFailure? failure;
  final int retryAttempt;
  final bool liveUpdates;
  final bool liveSnapshotSynchronized;
  final DateTime? lastLiveContact;
  final Duration readFreshness;
  final Duration liveFreshness;

  bool dataIsFreshAt(DateTime now) {
    if (lastSuccessfulRead == null) return false;
    if (_recent(lastSuccessfulRead, now, readFreshness)) return true;
    return liveUpdates &&
        liveSnapshotSynchronized &&
        _recent(lastLiveContact, now, liveFreshness);
  }

  HealthStatus statusAt(DateTime now) {
    if (!configured) return HealthStatus.notConfigured;
    if (failure == HealthFailure.authentication) {
      return HealthStatus.authenticationRequired;
    }
    if (failure == HealthFailure.permission) {
      return HealthStatus.permissionDenied;
    }
    if (retryAttempt > 0) return HealthStatus.retrying;
    if (connecting && lastContact == null) return HealthStatus.connecting;
    if (failure == HealthFailure.transport ||
        failure == HealthFailure.timeout) {
      return HealthStatus.offline;
    }
    if (failure != null) return HealthStatus.error;
    if (dataIsFreshAt(now)) return HealthStatus.healthy;
    if (lastSuccessfulRead != null) return HealthStatus.stale;
    if (lastContact != null) return HealthStatus.reachable;
    return HealthStatus.configured;
  }

  static bool _recent(DateTime? time, DateTime now, Duration limit) =>
      time != null && !now.isBefore(time) && now.difference(time) <= limit;

  IntegrationHealth copyWith({
    bool? connecting,
    DateTime? lastContact,
    DateTime? lastSuccessfulRead,
    DateTime? lastFailureAt,
    HealthFailure? failure,
    bool clearFailure = false,
    int? retryAttempt,
    bool? liveUpdates,
    bool? liveSnapshotSynchronized,
    DateTime? lastLiveContact,
  }) => IntegrationHealth(
    configured: configured,
    connecting: connecting ?? this.connecting,
    lastContact: lastContact ?? this.lastContact,
    lastSuccessfulRead: lastSuccessfulRead ?? this.lastSuccessfulRead,
    lastFailureAt: lastFailureAt ?? this.lastFailureAt,
    failure: clearFailure ? null : failure ?? this.failure,
    retryAttempt: retryAttempt ?? this.retryAttempt,
    liveUpdates: liveUpdates ?? this.liveUpdates,
    liveSnapshotSynchronized:
        liveSnapshotSynchronized ?? this.liveSnapshotSynchronized,
    lastLiveContact: lastLiveContact ?? this.lastLiveContact,
    readFreshness: readFreshness,
    liveFreshness: liveFreshness,
  );
}
