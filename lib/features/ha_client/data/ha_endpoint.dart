/// Shared URL handling for REST and WebSocket connections, including an
/// optional same-origin reverse-proxy prefix.
String normalizeHaBaseUrl(String value) {
  final trimmed = value.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      trimmed.contains(RegExp(r'\s'))) {
    throw const FormatException(
      'Enter a valid HTTP or HTTPS Home Assistant URL.',
    );
  }
  return uri.toString().replaceFirst(RegExp(r'/+$'), '');
}

Uri haApiUri(
  String baseUrl,
  String path, {
  Map<String, String>? queryParameters,
}) {
  final relative = Uri.tryParse(path);
  if (relative == null ||
      relative.hasScheme ||
      relative.hasAuthority ||
      relative.hasFragment ||
      !relative.path.startsWith('/api/') ||
      relative.pathSegments.any(
        (segment) =>
            segment == '.' ||
            segment == '..' ||
            segment.contains('/') ||
            segment.contains('\\'),
      ) ||
      path.startsWith('//') ||
      path.contains('\\')) {
    throw const FormatException('Use a relative Home Assistant /api/ path.');
  }
  final uri = Uri.parse('$baseUrl$path');
  if (queryParameters == null || queryParameters.isEmpty) return uri;
  return uri.replace(
    queryParameters: {...uri.queryParameters, ...queryParameters},
  );
}

String haPathSegment(String value) {
  if (value.isEmpty ||
      value == '.' ||
      value == '..' ||
      value.contains(RegExp(r'[/\\\x00-\x1f]'))) {
    throw const FormatException('Invalid API path identifier.');
  }
  return Uri.encodeComponent(value);
}
