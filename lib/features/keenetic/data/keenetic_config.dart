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
    final trimmed = value.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        trimmed.contains(RegExp(r'\s'))) {
      throw const FormatException('Invalid router URL.');
    }
    return uri.toString().replaceFirst(RegExp(r'/+$'), '');
  }
}
