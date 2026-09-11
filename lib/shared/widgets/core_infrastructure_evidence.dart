import 'package:flutter/cupertino.dart';

import '../../features/health/data/connection_evidence.dart';
import 'connection_evidence_status.dart';

/// Maps Core-backed infrastructure reads to the app-wide evidence vocabulary.
///
/// This helper is passive: it cannot open a transport, read credentials, use a
/// local cache fallback, retry, or promote an unverified result to success.
ConnectionEvidence coreInfrastructureEvidence({
  bool busy = false,
  bool stale = false,
  String? failure,
  DateTime? verifiedAt,
  bool transportObserved = false,
}) {
  final stage = verifiedAt != null
      ? ConnectionEvidenceStage.verified
      : transportObserved
      ? ConnectionEvidenceStage.reachable
      : ConnectionEvidenceStage.saved;
  if (busy) return ConnectionEvidence.connecting(stage: stage);
  if (stale) return ConnectionEvidence.stale(verifiedAt);
  if (failure != null) {
    if ({
      'forbidden',
      'not_found',
      'keenetic_upstream_denied',
    }.contains(failure)) {
      return ConnectionEvidence.permissionDenied(
        stage: stage,
        lastVerifiedAt: verifiedAt,
      );
    }
    if ({
      'unauthorized',
      'proxmox_upstream_unauthorized',
      'keenetic_upstream_unauthorized',
    }.contains(failure)) {
      return ConnectionEvidence.authenticationRequired(
        stage: stage,
        lastVerifiedAt: verifiedAt,
      );
    }
    if ({
      'connection_failed',
      'timeout',
      'proxmox_upstream_unavailable',
      'keenetic_upstream_unavailable',
    }.contains(failure)) {
      return ConnectionEvidence.unavailable(
        stage: stage,
        lastVerifiedAt: verifiedAt,
      );
    }
    return ConnectionEvidence.error(stage: stage, lastVerifiedAt: verifiedAt);
  }
  if (verifiedAt != null) return ConnectionEvidence.verified(verifiedAt);
  if (transportObserved) return const ConnectionEvidence.reachable();
  return const ConnectionEvidence.saved();
}

/// Maps explicit command state without claiming that an unknown outcome won.
/// A command receipt proves Core reachability; only a timestamped domain read
/// may become verified evidence.
ConnectionEvidence coreInfrastructureOperationEvidence({
  bool pending = false,
  bool succeeded = false,
  bool unknown = false,
  bool failed = false,
}) {
  if (pending) {
    return const ConnectionEvidence.connecting(
      stage: ConnectionEvidenceStage.reachable,
    );
  }
  if (unknown) return const ConnectionEvidence.stale();
  if (failed) {
    return const ConnectionEvidence.error(
      stage: ConnectionEvidenceStage.reachable,
    );
  }
  if (succeeded) return const ConnectionEvidence.reachable();
  return const ConnectionEvidence.saved();
}

/// Adds a surface-specific key while retaining the shared status semantics.
class CoreInfrastructureEvidenceStatus extends StatelessWidget {
  const CoreInfrastructureEvidenceStatus({
    super.key,
    required this.surface,
    required this.evidence,
    this.compact = false,
    this.showTimestamp = true,
  });

  final String surface;
  final ConnectionEvidence evidence;
  final bool compact, showTimestamp;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: ValueKey('$surface-evidence'),
    child: ConnectionEvidenceStatus(
      evidence: evidence,
      compact: compact,
      showTimestamp: showTimestamp,
    ),
  );
}
