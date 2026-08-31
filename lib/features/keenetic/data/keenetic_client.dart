import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'keenetic_api_exception.dart';
import 'keenetic_config.dart';
import 'models/keenetic_access_point.dart';
import 'models/keenetic_device.dart';
import 'models/keenetic_port_forward.dart';

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
    : _client = httpClient ?? http.Client();

  final KeeneticConfig config;
  final http.Client _client;

  String? _sessionCookie;

  Uri _uri(String path) => Uri.parse('${config.baseUrl}$path');

  Map<String, String> get _headers {
    final cookie = _sessionCookie;
    return {'Cookie': ?cookie};
  }

  Future<void> login() async {
    final initial = await _client
        .get(_uri('/auth'))
        .timeout(const Duration(seconds: 10));
    if (initial.statusCode == 200) {
      _storeCookie(initial);
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
          headers: {'Content-Type': 'application/json'},
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
    if (_sessionCookie == null) {
      throw KeeneticApiException('Router did not return a session cookie.');
    }
  }

  void _storeCookie(http.Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null) return;
    _sessionCookie = setCookie.split(';').first;
  }

  Future<void> checkConnection() async {
    final response = await _client
        .get(_uri('/rci/show/version'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw KeeneticApiException('Could not reach the router.');
    }
  }

  Future<List<KeeneticDevice>> getConnectedDevices() async {
    final response = await _client
        .get(_uri('/rci/show/ip/hotspot'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final decoded = jsonDecode(response.body);
    final list = decoded is Map<String, dynamic>
        ? (decoded['host'] as List<dynamic>? ?? const [])
        : decoded as List<dynamic>;
    return list
        .map((e) => KeeneticDevice.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<KeeneticAccessPoint>> getAccessPoints() async {
    final response = await _client
        .get(_uri('/rci/show/interface'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final decoded = jsonDecode(response.body);
    final entries = decoded is Map<String, dynamic>
        ? decoded.values
        : decoded as List<dynamic>;
    return entries
        .cast<Map<String, dynamic>>()
        .where((e) => e['type'] == 'AccessPoint')
        .map(KeeneticAccessPoint.fromJson)
        .toList();
  }

  /// Sends an RCI "parse" command — the same syntax as Keenetic's CLI,
  /// wrapped as JSON. Used here for `interface <id> up`/`down`.
  Future<void> setInterfaceUp(String interfaceId, bool up) async {
    final response = await _client
        .post(
          _uri('/rci/'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode([
            {'parse': 'interface $interfaceId ${up ? 'up' : 'down'}'},
          ]),
        )
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
  }

  Future<List<KeeneticPortForward>> getPortForwardingRules() async {
    final response = await _client
        .get(_uri('/rci/ip/static'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final decoded = jsonDecode(response.body);
    final list = decoded is List
        ? decoded
        : (decoded as Map<String, dynamic>)['static'] as List<dynamic>? ??
              const [];
    return list
        .map((e) => KeeneticPortForward.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  void _checkOk(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KeeneticApiException('Request failed (${response.statusCode}).');
    }
  }

  void dispose() => _client.close();
}
