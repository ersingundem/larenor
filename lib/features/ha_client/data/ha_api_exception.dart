class HaApiException implements Exception {
  HaApiException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

  @override
  String toString() => 'HaApiException: $message';
}
