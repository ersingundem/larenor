enum WellbeingSource { homeAssistant, healthConnect, healthKit, huaweiHealth }

enum WellbeingMetric { bodyMass, bodyFatPercentage, steps }

enum WellbeingAvailability {
  available,
  unsupportedPlatform,
  unavailableOnDevice,
  installOrUpdateRequired,
  providerRegistrationRequired,
  integrationPending,
  notConfigured,
}

enum WellbeingPermission { notRequested, granted, denied, unknown }

enum WellbeingReadState { unread, data, empty, emptyOrNotShared, failed }

enum WellbeingFailure {
  locked,
  cancelled,
  unavailable,
  permission,
  accountChanged,
  invalidData,
  sourceChanged,
  timeout,
  readFailed,
  storageFailed,
}

class WellbeingException implements Exception {
  const WellbeingException(this.failure);
  final WellbeingFailure failure;
  @override
  String toString() => 'WellbeingException(${failure.name})';
}

/// Ephemeral gate result, never a persisted consent flag or provider family key.
class WellbeingAccessSession {
  const WellbeingAccessSession({required this.isCurrent});
  final bool Function() isCurrent;
}

class HaWellbeingBinding {
  const HaWellbeingBinding({
    required this.id,
    required this.accountFingerprint,
    required this.entityId,
    required this.metric,
    required this.profileLabel,
  });
  final String id;
  final String accountFingerprint;
  final String entityId;
  final WellbeingMetric metric;
  final String profileLabel;
}

class WellbeingSettings {
  WellbeingSettings({
    this.enabled = false,
    this.profileLabel = '',
    Set<WellbeingMetric> nativeMetrics = const {},
    List<HaWellbeingBinding> bindings = const [],
  }) : nativeMetrics = Set.unmodifiable(nativeMetrics),
       bindings = List.unmodifiable(bindings);
  final bool enabled;
  final String profileLabel;
  final Set<WellbeingMetric> nativeMetrics;
  final List<HaWellbeingBinding> bindings;
}

class WellbeingProviderStatus {
  WellbeingProviderStatus({
    required this.source,
    required this.availability,
    Map<WellbeingMetric, WellbeingPermission> permissions = const {},
    this.checkedAt,
    this.failure,
  }) : permissions = Map.unmodifiable(permissions);
  final WellbeingSource source;
  final WellbeingAvailability availability;
  final Map<WellbeingMetric, WellbeingPermission> permissions;
  final DateTime? checkedAt;
  final WellbeingFailure? failure;
}

/// Only the mapped scalar is retained. HA attributes and native record metadata
/// are intentionally not included. Default Object.toString reveals no fields.
class WellbeingMeasurement {
  const WellbeingMeasurement({
    required this.source,
    required this.metric,
    required this.value,
    required this.unit,
    required this.profileLabel,
    required this.readAt,
    this.sourceRecordId,
    this.originName,
    this.originalValue,
    this.originalUnit,
    this.measuredAt,
    this.intervalEnd,
    this.sourceUpdatedAt,
  });
  final WellbeingSource source;
  final WellbeingMetric metric;
  final double value;
  final String unit;
  final String profileLabel;
  final DateTime readAt;
  final String? sourceRecordId;
  final String? originName;
  final double? originalValue;
  final String? originalUnit;
  final DateTime? measuredAt;
  final DateTime? intervalEnd;
  final DateTime? sourceUpdatedAt;
}

class WellbeingReadResult {
  WellbeingReadResult({
    required this.source,
    required this.metric,
    required this.state,
    List<WellbeingMeasurement> measurements = const [],
    this.readAt,
    this.failure,
    this.truncated = false,
  }) : measurements = List.unmodifiable(measurements);
  final WellbeingSource source;
  final WellbeingMetric metric;
  final WellbeingReadState state;
  final List<WellbeingMeasurement> measurements;
  final DateTime? readAt;
  final WellbeingFailure? failure;
  final bool truncated;
}

class HaWellbeingCandidate {
  HaWellbeingCandidate({
    required this.entityId,
    required this.name,
    required this.unit,
    required this.accountFingerprint,
    required Set<WellbeingMetric> compatibleMetrics,
  }) : compatibleMetrics = Set.unmodifiable(compatibleMetrics);
  final String entityId;
  final String name;
  final String unit;
  final String accountFingerprint;
  final Set<WellbeingMetric> compatibleMetrics;
}

class WellbeingSnapshot {
  WellbeingSnapshot({
    Map<WellbeingSource, WellbeingProviderStatus> statuses = const {},
    List<WellbeingReadResult> results = const [],
    List<HaWellbeingCandidate> haCandidates = const [],
    this.busy = false,
    this.failure,
  }) : statuses = Map.unmodifiable(statuses),
       results = List.unmodifiable(results),
       haCandidates = List.unmodifiable(haCandidates);
  final Map<WellbeingSource, WellbeingProviderStatus> statuses;
  final List<WellbeingReadResult> results;
  final List<HaWellbeingCandidate> haCandidates;
  final bool busy;
  final WellbeingFailure? failure;
}
