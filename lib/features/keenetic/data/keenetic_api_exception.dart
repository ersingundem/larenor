import 'keenetic_telemetry.dart';

/// Safe, typed failure. Never include a server response body or credentials.
class KeeneticApiException implements Exception {
  KeeneticApiException(
    this.message, {
    this.statusCode,
    this.failure = KeeneticReadFailure.invalidResponse,
  });
  final String message;
  final int? statusCode;
  final KeeneticReadFailure failure;
  @override
  String toString() => 'KeeneticApiException: $message';
}
