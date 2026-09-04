import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'keenetic_api_exception.dart';
import 'keenetic_config.dart';
import 'models/keenetic_access_point.dart';
import 'models/keenetic_device.dart';
import 'models/keenetic_port_forward.dart';
import 'models/keenetic_router_status.dart';

/// Hand-rolled client over Keenetic's unofficial RCI HTTP API — not
/// officially documented, verified against two independent community
/// clients (`Noksa/gokeenapi` and `salatmaster/keenetic-mcp`'s RCI
/// reference), not the Python `ndms2-client` HA depends on, which turned
/// out to use Telnet rather than HTTP.
///
/// Auth is a challenge/response flow, not a token: `GET /auth` returns
/// 401 with `X-NDM-Challenge`/`X-NDM-Realm` headers; the client computes
/// `sha256(challenge + md5("$login:$realm:$password"))` and POSTs it back,
/// then replays the resulting session cookie on every later request.
class KeeneticClient {
  KeeneticClient({required this.config, http.Client? httpClient})
    : _client = httpClient ?? http.Client(),
      _baseUrl = KeeneticConfig.normalizeBaseUrl(config.baseUrl);

  final KeeneticConfig config;
  final http.Client _client;
  final String _baseUrl;

  final Map<String, String> _cookies = {};
  Future<void>? _loginFuture;
  int _sessionGeneration = 0;

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  Map<String, String> get _headers {
    return {
      'Accept': 'application/json',
      if (_cookies.isNotEmpty)
        'Cookie': _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
    };
  }

  /// Share a single challenge/response exchange when several providers
  /// discover an expired session at the same time.
  Future<void> login() =>
      _loginFuture ??= _authenticate().whenComplete(() => _loginFuture = null);

  Future<void> _authenticate() async {
    final initial = await _client
        .get(_uri('/auth'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    // The router ties the challenge below to the session cookie it issues
    // on this very first response — capture it even though the request is
    // unauthenticated (401), and replay it on the POST, or the router
    // rejects an otherwise-correct challenge/response with 400.
    _storeCookie(initial);
    if (initial.statusCode == 200) {
      _sessionGeneration++;
      return;
    }
    if (initial.statusCode != 401) {
      throw KeeneticApiException(
        'Unexpected /auth response (${initial.statusCode}).',
      );
    }

    final challenge = initial.headers['x-ndm-challenge'];
    final realm = initial.headers['x-ndm-realm'];
    if (challenge == null || realm == null) {
      throw KeeneticApiException('Router did not send an auth challenge.');
    }

    final md5Hex = md5
        .convert(utf8.encode('${config.username}:$realm:${config.password}'))
        .toString();
    final passwordHash = sha256
        .convert(utf8.encode('$challenge$md5Hex'))
        .toString();

    final response = await _client
        .post(
          _uri('/auth'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'login': config.username,
            'password': passwordHash,
          }),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw KeeneticApiException('Login failed (${response.statusCode}).');
    }
    _storeCookie(response);
    if (_cookies.isEmpty) {
      throw KeeneticApiException('Router did not return a session cookie.');
    }
    _sessionGeneration++;
  }

  void _storeCookie(http.Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null) return;
    // package:http combines multiple Set-Cookie headers with a comma. Do
    // not split the comma inside an Expires attribute, or discard another
    // session cookie when a router rotates only one of them.
    for (final cookie in setCookie.split(RegExp(r',(?=\s*[^;,=\s]+=)'))) {
      final pair = cookie.split(';').first.trim();
      final equals = pair.indexOf('=');
      if (equals <= 0) continue;
      final name = pair.substring(0, equals);
      final value = pair.substring(equals + 1);
      if (value.isEmpty ||
          RegExp(r'max-age\s*=\s*0', caseSensitive: false).hasMatch(cookie)) {
        _cookies.remove(name);
      } else {
        _cookies[name] = value;
      }
    }
  }

  Future<void> checkConnection() async {
    _object(await _request('/rci/show/version'));
  }

  Future<KeeneticRouterStatus> getRouterStatus() async {
    final responses = await Future.wait([
      _request('/rci/show/version'),
      _request('/rci/show/system'),
    ]);
    return KeeneticRouterStatus.fromJson(
      _object(responses[0]),
      _object(responses[1]),
    );
  }

  Future<List<KeeneticDevice>> getConnectedDevices() async {
    final decoded = await _request('/rci/show/ip/hotspot');
    final devices = _list(
      decoded,
      'host',
    ).map(KeeneticDevice.fromJson).toList();
    devices.sort((a, b) {
      if (a.active != b.active) return a.active ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return devices;
  }

  Future<List<KeeneticAccessPoint>> getAccessPoints() async {
    final decoded = await _request('/rci/show/interface');
    // Some firmware indexes interfaces by ID and omits it from each value.
    final Iterable<Map<String, dynamic>> entries;
    if (decoded is Map<String, dynamic>) {
      entries = decoded.entries
          .where((entry) => entry.value is Map<String, dynamic>)
          .map(
            (entry) => {
              'id': entry.key,
              ...entry.value as Map<String, dynamic>,
            },
          );
    } else {
      entries = _list(decoded, 'interface');
    }
    return entries
        .where((e) => e['type'] == 'AccessPoint')
        .map(KeeneticAccessPoint.fromJson)
        .toList();
  }

  /// Sends an RCI "parse" command — the same syntax as Keenetic's CLI,
  /// wrapped as JSON. Used here for `interface <id> up`/`down`.
  Future<void> setInterfaceUp(String interfaceId, bool up) async {
    if (parseKeeneticWifiInterfaceId(interfaceId) == null) {
      throw KeeneticApiException('Invalid Wi-Fi interface.');
    }
    // Execute and persist in one router-side batch: disabling the current
    // Wi-Fi link can disconnect the app before a second request is sent.
    // https://support.keenetic.com/explorer/kn-1613/en/18480-command-line-interface--cli-.html
    await _request(
      '/rci/',
      body: [
        {'parse': 'interface $interfaceId ${up ? 'up' : 'down'}'},
        {'parse': 'system configuration save'},
      ],
    );
  }

  Future<List<KeeneticPortForward>> getPortForwardingRules() async {
    final decoded = await _request('/rci/ip/static');
    return _list(decoded, 'static').map(KeeneticPortForward.fromJson).toList();
  }

  Future<Object?> _request(String path, {Object? body}) async {
    Future<http.Response> send() =>
        (body == null
                ? _client.get(_uri(path), headers: _headers)
                : _client.post(
                    _uri(path),
                    headers: {..._headers, 'Content-Type': 'application/json'},
                    body: jsonEncode(body),
                  ))
            .timeout(const Duration(seconds: 15));

    final generation = _sessionGeneration;
    var response = await send();
    if (response.statusCode == 401) {
      if (generation == _sessionGeneration) await login();
      // Retry only an explicit authentication rejection, never a timeout
      // or other ambiguous failure that could duplicate a router command.
      response = await send();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KeeneticApiException('Request failed (${response.statusCode}).');
    }
    _storeCookie(response);
    if (body != null && response.body.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw KeeneticApiException('Router returned an invalid response.');
    }
    _checkCommandResult(decoded);
    return decoded;
  }

  void _checkCommandResult(Object? value) {
    if (value is List) {
      for (final entry in value) {
        _checkCommandResult(entry);
      }
    } else if (value is Map<String, dynamic>) {
      if (value['status'] == 'error' || value['status'] == 'fail') {
        throw KeeneticApiException(
          value['message'] is String
              ? value['message'] as String
              : 'Router rejected the command.',
        );
      }
      // Both {parse: [{status: ...}]} and {status: [{status: ...}]} are
      // emitted by RCI. Check those envelopes even for HTTP 200 responses.
      for (final key in ['parse', 'status']) {
        final nested = value[key];
        if (nested is List || nested is Map<String, dynamic>) {
          _checkCommandResult(nested);
        }
      }
    }
  }

  Map<String, dynamic> _object(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw KeeneticApiException('Router returned an unexpected response.');
    }
    return value;
  }

  Iterable<Map<String, dynamic>> _list(Object? value, String key) {
    final entries = value is Map<String, dynamic>
        ? value[key] ?? const []
        : value;
    if (entries is! List) {
      throw KeeneticApiException('Router returned an unexpected response.');
    }
    return entries.whereType<Map<String, dynamic>>();
  }

  void dispose() => _client.close();
}
