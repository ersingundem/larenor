import '../../../shared/network/server_bound_client.dart' show parseServerUrl;

class KeeneticConfig {
  const KeeneticConfig({
    required this.baseUrl,
    required this.username,
    required this.password,
  });

  final String baseUrl;
  final String username;
  final String password;

  /// Accept an origin or reverse-proxy prefix, but never credentials,
  /// query strings or fragments in the router address.
  static String normalizeBaseUrl(String value) {
    try {
      return parseServerUrl(value).toString();
    } on FormatException {
      throw const FormatException('Invalid router URL.');
    }
  }
}
