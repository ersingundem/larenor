import 'dart:convert';

import 'package:http/http.dart' as http;

/// An authenticated integration transport may only contact its configured
/// server. Custom API-key headers are not stripped by Dart's automatic redirect
/// handling, so even same-host redirects are left for the user to configure.
class ServerBoundClient extends http.BaseClient {
  ServerBoundClient({required String baseUrl, http.Client? inner})
    : baseUri = parseServerUrl(baseUrl),
      _inner = inner ?? http.Client();

  final Uri baseUri;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!isWithinServer(baseUri, request.url)) {
      throw http.ClientException('Request is outside the configured server.');
    }
    if (request.headers.values.any(
      (value) => value.contains(RegExp(r'[\r\n]')),
    )) {
      throw http.ClientException('Invalid request header.');
    }
    request.followRedirects = false;
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } on http.ClientException {
      // Platform errors can include URLs with authentication query parameters.
      throw http.ClientException('Could not connect to the configured server.');
    }
    if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
      await response.stream.listen((_) {}).cancel();
      throw http.ClientException(
        'Server redirected the request. Use its final URL in connection settings.',
      );
    }
    return http.StreamedResponse(
      _safeResponseStream(response.stream),
      response.statusCode,
      contentLength: response.contentLength,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
      request: response.request,
    );
  }

  Stream<List<int>> _safeResponseStream(Stream<List<int>> stream) async* {
    try {
      await for (final chunk in stream) {
        yield chunk;
      }
    } on http.ClientException {
      throw http.ClientException(
        'Could not read the configured server response.',
      );
    }
  }

  @override
  void close() => _inner.close();
}

Uri parseServerUrl(String value) {
  final input = value.trim();
  final uri = Uri.tryParse(input);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      _safeDecodedPath(uri.path) == null ||
      input.contains(RegExp(r'[\s\\]'))) {
    throw const FormatException('Invalid server URL.');
  }
  return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
}

bool isWithinServer(Uri server, Uri destination) {
  if (destination.scheme != server.scheme ||
      destination.host != server.host ||
      destination.port != server.port ||
      destination.userInfo.isNotEmpty ||
      destination.hasFragment) {
    return false;
  }
  final prefix = _safeDecodedPath(server.path)
      ?.replaceFirst(RegExp(r'/+$'), '');
  final path = _safeDecodedPath(destination.path);
  if (prefix == null || path == null) return false;
  return prefix.isEmpty || path == prefix || path.startsWith('$prefix/');
}

String? _safeDecodedPath(String path) {
  // Proxies may decode a path again. Check each layer before comparing the
  // server prefix, including encoded separators adjacent to dot segments.
  final escaped = RegExp(r'%[0-9a-f]{2}', caseSensitive: false);
  for (var depth = 0; depth < 8; depth++) {
    if (path.contains(RegExp(r'[\\\x00-\x1f\x7f]')) ||
        path.split('/').any((segment) => segment == '.' || segment == '..')) {
      return null;
    }
    if (!escaped.hasMatch(path)) return path;
    try {
      path = Uri.decodeComponent(path);
    } on FormatException {
      return null;
    }
  }
  return null;
}

/// Keep useful server validation errors without echoing credentials or entire
/// proxy responses into widgets, crash reports, or logs.
String redactServerMessage(String message, Iterable<String?> secrets) {
  var safe = message;
  for (final secret in secrets) {
    if (secret == null || secret.isEmpty) continue;
    for (final form in {secret, Uri.encodeComponent(secret)}) {
      safe = safe.replaceAll(form, '[redacted]');
    }
  }
  return safe.length <= 1000 ? safe : '${safe.substring(0, 1000)}…';
}

/// FormatException normally includes its source text. An API response can
/// contain credentials, so a malformed response must not become an error dump.
Object? decodeServerJson(String body) {
  try {
    return jsonDecode(body);
  } on FormatException {
    throw const FormatException('Server returned an invalid JSON response.');
  }
}
