/// Exception type for the Keenetic client — mirrors `HaApiException` /
/// `MediaApiException` / `ProxmoxApiException`'s role, kept separate since
/// Keenetic is an unrelated service with its own auth model.
class KeeneticApiException implements Exception {
  KeeneticApiException(this.message);

  final String message;

  @override
  String toString() => 'KeeneticApiException: $message';
}
