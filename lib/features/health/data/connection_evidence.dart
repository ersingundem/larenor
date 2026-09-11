import 'integration_health.dart';

/// The strongest observation Larenor has for one connection target.
///
/// Stages are progressive: a saved endpoint is local configuration, a
/// reachable service is transport contact, and a verified result is a fully
/// parsed domain read. Conditions describe why that evidence cannot currently
/// be treated as fresh. No constructor promotes a transport response to a
/// verified result.
enum ConnectionEvidenceStage { none, saved, reachable, verified }

enum ConnectionEvidenceCondition {
  current,
  connecting,
  retrying,
  stale,
  offline,
  authenticationRequired,
  permissionDenied,
  error,
}

final class ConnectionEvidence {
  const ConnectionEvidence._({
    required this.stage,
    required this.condition,
    this.lastVerifiedAt,
  }) : assert(
         stage != ConnectionEvidenceStage.verified || lastVerifiedAt != null,
         'Verified evidence needs a verified read time.',
       );

  const ConnectionEvidence.none()
    : this._(
        stage: ConnectionEvidenceStage.none,
        condition: ConnectionEvidenceCondition.current,
      );

  const ConnectionEvidence.saved()
    : this._(
        stage: ConnectionEvidenceStage.saved,
        condition: ConnectionEvidenceCondition.current,
      );

  const ConnectionEvidence.reachable()
    : this._(
        stage: ConnectionEvidenceStage.reachable,
        condition: ConnectionEvidenceCondition.current,
      );

  const ConnectionEvidence.connecting({
    ConnectionEvidenceStage stage = ConnectionEvidenceStage.saved,
  }) : this._(stage: stage, condition: ConnectionEvidenceCondition.connecting);

  const ConnectionEvidence.retrying({
    ConnectionEvidenceStage stage = ConnectionEvidenceStage.saved,
    DateTime? lastVerifiedAt,
  }) : this._(
         stage: stage,
         condition: ConnectionEvidenceCondition.retrying,
         lastVerifiedAt: lastVerifiedAt,
       );

  const ConnectionEvidence.verified(DateTime verifiedAt)
    : this._(
        stage: ConnectionEvidenceStage.verified,
        condition: ConnectionEvidenceCondition.current,
        lastVerifiedAt: verifiedAt,
      );

  const ConnectionEvidence.stale([DateTime? verifiedAt])
    : this._(
        stage: verifiedAt == null
            ? ConnectionEvidenceStage.reachable
            : ConnectionEvidenceStage.verified,
        condition: ConnectionEvidenceCondition.stale,
        lastVerifiedAt: verifiedAt,
      );

  const ConnectionEvidence.unavailable({
    this.stage = ConnectionEvidenceStage.saved,
    this.lastVerifiedAt,
  }) : condition = ConnectionEvidenceCondition.offline,
       assert(
         stage != ConnectionEvidenceStage.verified || lastVerifiedAt != null,
         'Verified evidence needs a verified read time.',
       );

  const ConnectionEvidence.authenticationRequired({
    this.stage = ConnectionEvidenceStage.reachable,
    this.lastVerifiedAt,
  }) : condition = ConnectionEvidenceCondition.authenticationRequired,
       assert(
         stage != ConnectionEvidenceStage.verified || lastVerifiedAt != null,
         'Verified evidence needs a verified read time.',
       );

  const ConnectionEvidence.permissionDenied({
    this.stage = ConnectionEvidenceStage.reachable,
    this.lastVerifiedAt,
  }) : condition = ConnectionEvidenceCondition.permissionDenied,
       assert(
         stage != ConnectionEvidenceStage.verified || lastVerifiedAt != null,
         'Verified evidence needs a verified read time.',
       );

  const ConnectionEvidence.error({
    this.stage = ConnectionEvidenceStage.reachable,
    this.lastVerifiedAt,
  }) : condition = ConnectionEvidenceCondition.error,
       assert(
         stage != ConnectionEvidenceStage.verified || lastVerifiedAt != null,
         'Verified evidence needs a verified read time.',
       );

  final ConnectionEvidenceStage stage;
  final ConnectionEvidenceCondition condition;
  final DateTime? lastVerifiedAt;

  bool get isFreshVerified =>
      stage == ConnectionEvidenceStage.verified &&
      condition == ConnectionEvidenceCondition.current;

  HealthStatus get status => switch (condition) {
    ConnectionEvidenceCondition.connecting => HealthStatus.connecting,
    ConnectionEvidenceCondition.retrying => HealthStatus.retrying,
    ConnectionEvidenceCondition.stale => HealthStatus.stale,
    ConnectionEvidenceCondition.offline => HealthStatus.offline,
    ConnectionEvidenceCondition.authenticationRequired =>
      HealthStatus.authenticationRequired,
    ConnectionEvidenceCondition.permissionDenied =>
      HealthStatus.permissionDenied,
    ConnectionEvidenceCondition.error => HealthStatus.error,
    ConnectionEvidenceCondition.current => switch (stage) {
      ConnectionEvidenceStage.none => HealthStatus.notConfigured,
      ConnectionEvidenceStage.saved => HealthStatus.configured,
      ConnectionEvidenceStage.reachable => HealthStatus.reachable,
      ConnectionEvidenceStage.verified => HealthStatus.healthy,
    },
  };

  factory ConnectionEvidence.fromHealth(
    IntegrationHealth health,
    HealthStatus observedStatus,
  ) {
    if (!health.configured) {
      return observedStatus == HealthStatus.configured
          ? const ConnectionEvidence.saved()
          : const ConnectionEvidence.none();
    }
    final verifiedAt = health.lastSuccessfulRead;
    final stage = verifiedAt != null
        ? ConnectionEvidenceStage.verified
        : health.lastContact != null
        ? ConnectionEvidenceStage.reachable
        : health.configured
        ? ConnectionEvidenceStage.saved
        : ConnectionEvidenceStage.none;
    return switch (observedStatus) {
      HealthStatus.notConfigured => const ConnectionEvidence.none(),
      HealthStatus.configured => const ConnectionEvidence.saved(),
      HealthStatus.connecting => ConnectionEvidence.connecting(stage: stage),
      HealthStatus.reachable => const ConnectionEvidence.reachable(),
      // A contradictory healthy status cannot invent a verified domain read.
      HealthStatus.healthy =>
        verifiedAt == null
            ? stage == ConnectionEvidenceStage.reachable
                  ? const ConnectionEvidence.reachable()
                  : const ConnectionEvidence.saved()
            : ConnectionEvidence.verified(verifiedAt),
      HealthStatus.stale => ConnectionEvidence.stale(verifiedAt),
      HealthStatus.retrying => ConnectionEvidence.retrying(
        stage: stage,
        lastVerifiedAt: verifiedAt,
      ),
      HealthStatus.offline => ConnectionEvidence.unavailable(
        stage: stage,
        lastVerifiedAt: verifiedAt,
      ),
      HealthStatus.authenticationRequired =>
        ConnectionEvidence.authenticationRequired(
          stage: stage,
          lastVerifiedAt: verifiedAt,
        ),
      HealthStatus.permissionDenied => ConnectionEvidence.permissionDenied(
        stage: stage,
        lastVerifiedAt: verifiedAt,
      ),
      HealthStatus.error => ConnectionEvidence.error(
        stage: stage,
        lastVerifiedAt: verifiedAt,
      ),
    };
  }
}
