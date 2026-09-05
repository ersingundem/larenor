/// Reject ambiguous URLs before they reach WebView's parser. Queries and
/// fragments are allowed; credentials and encoded control bytes are not.
String? dashboardWebsiteUrl(String input) {
  if (input.length > 4096 || RegExp(r'[\x00-\x20\x7f\\]').hasMatch(input)) {
    return null;
  }
  try {
    final authority = RegExp(
      r'^https?://([^/?#]*)',
      caseSensitive: false,
    ).firstMatch(input)?.group(1);
    if (authority == null || authority.contains('@')) return null;
    final uri = Uri.parse(input);
    final decoded = Uri.decodeFull(input);
    if (RegExp(r'[\x00-\x1f\x7f\\]').hasMatch(decoded) ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        uri.port < 1 ||
        uri.port > 65535) {
      return null;
    }
    return uri.toString();
  } on FormatException {
    return null;
  }
}
