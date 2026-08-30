class HaConnectionConfig {
  const HaConnectionConfig({required this.baseUrl, required this.token});

  /// Normalized, no trailing slash, e.g. `http://homeassistant.local:8123`.
  final String baseUrl;
  final String token;

  static String normalizeBaseUrl(String input) {
    var url = input.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }
}
