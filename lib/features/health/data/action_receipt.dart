import 'integration_health.dart';

enum ActionStatus { sending, accepted, confirmed, failed, unknown }

enum ActionFailure {
  authentication,
  permission,
  rejected,
  notConnected,
  timeout,
  transport,
  observationLost,
  disposed,
  unknown,
}

/// Identifiers only. Do not put service payloads, URLs or credentials here.
class ActionKey {
  ActionKey({
    required this.integration,
    required this.target,
    required this.action,
  }) {
    final identifier = RegExp(r'^[a-zA-Z0-9_.:-]+$');
    if (target.length > 256 ||
        action.length > 128 ||
        !identifier.hasMatch(target) ||
        !identifier.hasMatch(action)) {
      throw ArgumentError('Action keys must contain identifiers only.');
    }
  }

  final IntegrationId integration;
  final String target;
  final String action;
}

/// Acknowledgement means server acceptance. Confirmation means a subsequent
/// observation matched the requested state, not proof of physical causality.
/// Actions with no observable expected result (such as scenes) stay accepted.
class ActionReceipt {
  const ActionReceipt({
    required this.id,
    required this.key,
    required this.createdAt,
    required this.status,
    this.acceptedAt,
    this.observedAt,
    this.completedAt,
    this.failure,
  });

  final int id;
  final ActionKey key;
  final DateTime createdAt;
  final ActionStatus status;
  final DateTime? acceptedAt;
  final DateTime? observedAt;
  final DateTime? completedAt;
  final ActionFailure? failure;

  ActionReceipt update({
    required ActionStatus status,
    DateTime? acceptedAt,
    DateTime? observedAt,
    DateTime? completedAt,
    ActionFailure? failure,
  }) => ActionReceipt(
    id: id,
    key: key,
    createdAt: createdAt,
    status: status,
    acceptedAt: acceptedAt ?? this.acceptedAt,
    observedAt: observedAt ?? this.observedAt,
    completedAt: completedAt,
    failure: failure,
  );
}

class ActionInProgressException implements Exception {
  const ActionInProgressException(this.receiptId);
  final int receiptId;
  @override
  String toString() => 'An action is already pending for this target.';
}

class ActionExecutionException implements Exception {
  const ActionExecutionException(this.receipt);
  final ActionReceipt receipt;
  @override
  String toString() => receipt.status == ActionStatus.unknown
      ? 'The action result is uncertain. Check the device before retrying.'
      : 'The action could not be completed.';
}
