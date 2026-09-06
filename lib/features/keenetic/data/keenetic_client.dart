import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../../shared/network/server_bound_client.dart';
import '../../health/data/health_monitor.dart';
import '../../health/data/integration_health.dart';
import 'keenetic_api_exception.dart';
import 'keenetic_config.dart';
import 'keenetic_telemetry.dart';
import 'models/keenetic_access_point.dart';
import 'models/keenetic_device.dart';
import 'models/keenetic_port_forward.dart';
import 'models/keenetic_router_status.dart';

part 'keenetic_telemetry_reader.dart';

/// RCI's command tree and show API are documented in KeeneticOS CLI Appendix B.
/// This client uses the local Web UI challenge/cookie authentication flow;
/// the separately configured HTTP Proxy Digest API is a different transport.
class KeeneticClient {
  KeeneticClient({
    required this.config,
    http.Client? httpClient,
    this.healthSession,
    this.requestTimeout = const Duration(seconds: 15),
    DateTime Function()? now,
    this._isCurrent,
  }) : _client = ServerBoundClient(baseUrl: config.baseUrl, inner: httpClient),
       _now = now ?? DateTime.now;

  final KeeneticConfig config;
  final ServerBoundClient _client;
  final HealthSession? healthSession;
  final Duration requestTimeout;
  final DateTime Function() _now;
  final bool Function()? _isCurrent;
  bool get _sourceCurrent {
    try {
      return _isCurrent?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  final _cookies = <String, (Cookie, DateTime?)>{};
  final _aborts = <Completer<void>>{};
  final _pendingMutations = <String>{};
  Future<void>? _loginFuture;
  int _sessionGeneration = 0;
  int _requestGeneration = 0;
  bool _disposed = false;
  bool _authenticated = false;
  bool get isAuthenticated => !_disposed && _sourceCurrent && _authenticated;

  Uri _uri(String path) =>
      _client.baseUri.replace(path: '${_client.baseUri.path}$path');
  void _checkActive([int? generation]) {
    if (!_sourceCurrent) dispose();
    if (_disposed || (generation != null && generation != _requestGeneration)) {
      throw KeeneticApiException(
        'Connection is no longer active.',
        failure: KeeneticReadFailure.inactive,
      );
    }
  }

  Map<String, String> _headers(Uri uri) {
    final now = _now();
    _cookies.removeWhere(
      (_, value) => value.$2 != null && !now.isBefore(value.$2!),
    );
    final matching = _cookies.values.where((entry) {
      final cookie = entry.$1;
      final path = cookie.path ?? '/';
      return (!cookie.secure || uri.scheme == 'https') &&
          (uri.path == path ||
              uri.path.startsWith(path.endsWith('/') ? path : '$path/'));
    });
    return {
      'Accept': 'application/json',
      if (matching.isNotEmpty)
        'Cookie': matching
            .map((entry) => '${entry.$1.name}=${entry.$1.value}')
            .join('; '),
    };
  }

  Future<void> login() {
    _checkActive();
    if (_loginFuture case final pending?) return pending;
    late final Future<void> future;
    future = _authenticate().whenComplete(() {
      if (identical(_loginFuture, future)) _loginFuture = null;
    });
    _loginFuture = future;
    return future;
  }

  Future<void> _authenticate() async {
    final generation = _requestGeneration;
    _authenticated = false;
    healthSession?.connecting();
    try {
      final initial = await _send('/auth');
      _checkActive(generation);
      if (initial.statusCode == 200) {
        _authenticated = true;
        _sessionGeneration++;
        return;
      }
      if (initial.statusCode != 401) throw _status(initial.statusCode);
      final challenge = initial.headers['x-ndm-challenge'];
      final realm = initial.headers['x-ndm-realm'];
      if (challenge == null ||
          realm == null ||
          challenge.length > 4096 ||
          realm.length > 4096) {
        throw _invalid();
      }
      final md5Hex = md5
          .convert(utf8.encode('${config.username}:$realm:${config.password}'))
          .toString();
      final response = await _send(
        '/auth',
        body: {
          'login': config.username,
          'password': sha256
              .convert(utf8.encode('$challenge$md5Hex'))
              .toString(),
        },
      );
      _checkActive(generation);
      if (response.statusCode != 200) throw _status(response.statusCode);
      if (_cookies.isEmpty) throw _invalid();
      _authenticated = true;
      _sessionGeneration++;
    } on KeeneticApiException catch (error) {
      if (!_disposed && generation == _requestGeneration) {
        _report(error.failure);
      }
      rethrow;
    }
  }

  void _storeCookie(http.Response response, Uri responseUri) {
    final header = response.headers['set-cookie'];
    if (header == null) return;
    if (header.length > 8192) throw _invalid();
    final parts = header.split(RegExp(r',(?=\s*[^;,=\s]+=)'));
    if (parts.length > 16) throw _invalid();
    for (final part in parts) {
      final Cookie cookie;
      try {
        cookie = Cookie.fromSetCookieValue(part.trim());
      } catch (_) {
        throw _invalid();
      }
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(cookie.name) ||
          cookie.value.contains(RegExp(r'[\x00-\x20\x7f;,]'))) {
        throw _invalid();
      }
      final domain = cookie.domain
          ?.replaceFirst(RegExp(r'^\.'), '')
          .toLowerCase();
      if (domain != null && domain != responseUri.host.toLowerCase()) continue;
      if (cookie.secure && responseUri.scheme != 'https') continue;
      // RFC6265 default-path is the response directory, not the entire origin.
      final path = cookie.path;
      if (path == null || !path.startsWith('/')) {
        final slash = responseUri.path.lastIndexOf('/');
        cookie.path = slash <= 0 ? '/' : responseUri.path.substring(0, slash);
      }
      final key = '${cookie.name}\n${cookie.path}';
      final maxAge = cookie.maxAge;
      final expires = maxAge == null
          ? cookie.expires
          : _now().add(Duration(seconds: maxAge.clamp(-1, 315360000)));
      if (cookie.value.isEmpty ||
          (expires != null && !_now().isBefore(expires))) {
        _cookies.remove(key);
      } else {
        _cookies[key] = (cookie, expires);
      }
      if (_cookies.length > 16) throw _invalid();
    }
  }

  Future<void> checkConnection() async {
    final version = _object(await _request('/rci/show/version'));
    if (![
      'model',
      'description',
      'release',
      'title',
    ].any((key) => keeneticText(version[key]) != null)) {
      throw _invalid();
    }
    healthSession?.readSucceeded();
  }

  Future<KeeneticRouterStatus> getRouterStatus() async {
    final responses = await Future.wait([
      _request('/rci/show/version'),
      _request('/rci/show/system'),
    ]);
    final result = KeeneticRouterStatus.fromJson(
      _object(responses[0]),
      _object(responses[1]),
    );
    healthSession?.readSucceeded();
    return result;
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
    healthSession?.readSucceeded();
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
    final result = entries
        .where((e) => e['type'] == 'AccessPoint')
        .map(KeeneticAccessPoint.fromJson)
        .toList();
    healthSession?.readSucceeded();
    return result;
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
    if (!_pendingMutations.add(interfaceId)) {
      throw KeeneticApiException(
        'An action is already pending for this interface.',
      );
    }
    try {
      await _request(
        '/rci/',
        readOnly: false,
        body: [
          {'parse': 'interface $interfaceId ${up ? 'up' : 'down'}'},
          {'parse': 'system configuration save'},
        ],
      );
    } finally {
      _pendingMutations.remove(interfaceId);
    }
  }

  Future<List<KeeneticPortForward>> getPortForwardingRules() async {
    final decoded = await _request('/rci/ip/static');
    final result = _list(
      decoded,
      'static',
    ).map(KeeneticPortForward.fromJson).toList();
    healthSession?.readSucceeded();
    return result;
  }

  Future<Object?> _request(
    String path, {
    Object? body,
    bool readOnly = true,
  }) async {
    _checkActive();
    final generation = _requestGeneration;
    try {
      final session = _sessionGeneration;
      var response = await _send(path, body: body);
      if (response.statusCode == 401 && readOnly) {
        if (session == _sessionGeneration) await login();
        _checkActive(generation);
        response = await _send(path, body: body);
      }
      _checkActive(generation);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _status(response.statusCode);
      }
      if (!readOnly && response.body.trim().isEmpty) return null;
      Object? decoded;
      try {
        decoded = decodeServerJson(response.body);
      } on FormatException {
        throw _invalid();
      }
      _checkCommandResult(decoded);
      return decoded;
    } on KeeneticApiException catch (error) {
      if (!_disposed && generation == _requestGeneration) {
        _report(error.failure);
      }
      rethrow;
    }
  }

  Future<http.Response> _send(String path, {Object? body}) async {
    _checkActive();
    final generation = _requestGeneration;
    final uri = _uri(path);
    final abort = Completer<void>();
    _aborts.add(abort);
    final request = http.AbortableRequest(
      body == null ? 'GET' : 'POST',
      uri,
      abortTrigger: abort.future,
    )..headers.addAll(_headers(uri));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final response =
          await (() async {
            final streamed = await _client.send(request);
            _checkActive(generation);
            healthSession?.contact();
            final bytes = <int>[];
            await for (final chunk in streamed.stream) {
              _checkActive(generation);
              if (bytes.length + chunk.length > 2 * 1024 * 1024) {
                throw _invalid();
              }
              bytes.addAll(chunk);
            }
            return http.Response.bytes(
              bytes,
              streamed.statusCode,
              headers: streamed.headers,
            );
          })().timeout(
            requestTimeout,
            onTimeout: () {
              if (!abort.isCompleted) abort.complete();
              throw TimeoutException('Read timed out.');
            },
          );
      _checkActive(generation);
      _storeCookie(response, uri);
      return response;
    } on KeeneticApiException {
      rethrow;
    } on TimeoutException {
      throw KeeneticApiException(
        'Router did not respond in time.',
        failure: KeeneticReadFailure.timeout,
      );
    } on IOException {
      throw KeeneticApiException(
        'Could not reach the router.',
        failure: KeeneticReadFailure.transport,
      );
    } on http.ClientException {
      throw KeeneticApiException(
        'Could not reach the router.',
        failure: KeeneticReadFailure.transport,
      );
    } catch (_) {
      throw _invalid();
    } finally {
      _aborts.remove(abort);
      if (!abort.isCompleted) abort.complete();
    }
  }

  KeeneticApiException _status(int code) => KeeneticApiException(
    'Router request failed (HTTP $code).',
    statusCode: code,
    failure: switch (code) {
      401 => KeeneticReadFailure.authentication,
      403 => KeeneticReadFailure.permission,
      404 || 405 || 501 => KeeneticReadFailure.unsupported,
      >= 500 => KeeneticReadFailure.server,
      _ => KeeneticReadFailure.invalidResponse,
    },
  );
  KeeneticApiException _invalid() => KeeneticApiException(
    'Router returned an invalid response.',
    failure: KeeneticReadFailure.invalidResponse,
  );
  void _report(KeeneticReadFailure failure) {
    if (failure == KeeneticReadFailure.inactive ||
        failure == KeeneticReadFailure.selectionRequired) {
      return;
    }
    healthSession?.failed(switch (failure) {
      KeeneticReadFailure.authentication => HealthFailure.authentication,
      KeeneticReadFailure.permission => HealthFailure.permission,
      KeeneticReadFailure.transport => HealthFailure.transport,
      KeeneticReadFailure.timeout => HealthFailure.timeout,
      KeeneticReadFailure.server ||
      KeeneticReadFailure.rejected => HealthFailure.server,
      _ => HealthFailure.invalidResponse,
    });
  }

  void _checkCommandResult(Object? value) {
    if (value is List) {
      for (final entry in value) {
        _checkCommandResult(entry);
      }
    } else if (value is Map<String, dynamic>) {
      if (value['status'] == 'error' || value['status'] == 'fail') {
        // Server error text can contain private addresses, command arguments or
        // credentials unknown to the app. It must not become display text.
        throw KeeneticApiException(
          'Router rejected the command.',
          failure: KeeneticReadFailure.rejected,
        );
      }
      for (final key in ['parse', 'status']) {
        final nested = value[key];
        if (nested is List || nested is Map<String, dynamic>) {
          _checkCommandResult(nested);
        }
      }
    }
  }

  Map<String, dynamic> _object(Object? value) {
    if (value is! Map<String, dynamic>) throw _invalid();
    return value;
  }

  List<Map<String, dynamic>> _list(Object? value, String key) {
    final entries = value is Map<String, dynamic> ? value[key] : value;
    if (entries is! List ||
        entries.length > 4096 ||
        entries.any((e) => e is! Map<String, dynamic>)) {
      throw _invalid();
    }
    return entries.cast<Map<String, dynamic>>();
  }

  /// Telemetry controllers use this on background/disposal. They own their
  /// client, so no unrelated screen's operation is interrupted.
  void cancelPendingReads() {
    _requestGeneration++;
    for (final abort in _aborts.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
    _authenticated = false;
    _loginFuture = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelPendingReads();
    _cookies.clear();
    _sessionGeneration++;
    _client.close();
  }
}
