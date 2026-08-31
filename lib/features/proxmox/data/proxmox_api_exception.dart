/// Exception type for the Proxmox client — mirrors `HaApiException` and
/// `MediaApiException`'s role, kept separate since Proxmox is an unrelated
/// service with its own auth model (ticket/cookie sessions, not tokens).
class ProxmoxApiException implements Exception {
  ProxmoxApiException(this.message);

  final String message;

  @override
  String toString() => 'ProxmoxApiException: $message';
}
