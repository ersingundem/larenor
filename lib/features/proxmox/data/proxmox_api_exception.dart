enum ProxmoxFailure {
  authentication,
  permission,
  transport,
  timeout,
  server,
  invalidResponse,
  inactive,
  actionPending,
}

/// Safe display text plus machine-readable cause; server error bodies are never
/// promoted into exceptions (they can contain unknown secrets/addresses).
class ProxmoxApiException implements Exception {
  ProxmoxApiException(
    this.message, {
    this.statusCode,
    this.failure = ProxmoxFailure.invalidResponse,
  });
  final String message;
  final int? statusCode;
  final ProxmoxFailure failure;
  @override
  String toString() => 'ProxmoxApiException: $message';
}
