/// Deliberately contains no URL, headers, body, exception or credential.
enum TransportObservationKind { response, completed, failed }

enum TransportFailure { connection, timeout }

class TransportObservation {
  const TransportObservation({
    required this.kind,
    required this.isRead,
    this.statusCode,
    this.failure,
  });

  final TransportObservationKind kind;
  final bool isRead;
  final int? statusCode;
  final TransportFailure? failure;
}

typedef TransportObserver = void Function(TransportObservation observation);

/// Monitoring must never change a request's success/failure semantics.
void notifyTransport(TransportObserver? observer, TransportObservation value) {
  try {
    observer?.call(value);
  } catch (_) {
    // Observers are optional diagnostics, not part of the transport contract.
  }
}
