class HaApiException implements Exception {
  HaApiException(this.message);

  final String message;

  @override
  String toString() => 'HaApiException: $message';
}
