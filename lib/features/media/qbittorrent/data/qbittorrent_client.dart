import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:qbittorrent_api/qbittorrent_api.dart';

import '../../../../shared/network/server_bound_client.dart';
import '../../../health/data/health_monitor.dart';
import '../../../health/data/integration_health.dart';
import '../../data/media_api_exception.dart';
import 'qbittorrent_config.dart';

/// A small Web API v2 adapter. SDK DTOs are retained; its unscoped Dio transport
/// is never instantiated. Session cookies live only in this client's memory.
class QbittorrentClient {
  QbittorrentClient({
    required QbittorrentConfig config,
    http.Client? httpClient,
    this.healthSession,
    this.requestTimeout = const Duration(seconds: 15),
    DateTime Function()? now,
  }) : _config = config,
       _http = ServerBoundClient(baseUrl: config.baseUrl, inner: httpClient),
       _now = now ?? DateTime.now;

  final QbittorrentConfig _config;
  final ServerBoundClient _http;
  final HealthSession? healthSession;
  final Duration requestTimeout;
  final DateTime Function() _now;
  late final torrents = QbittorrentTorrents(this);
  Cookie? _cookie;
  DateTime? _cookieExpires;
  int? _appMajor;
  bool _disposed = false;
  bool _loggingIn = false;
  int _sessionGeneration = 0;
  final _pendingMutations = <String>{};
  final _requestAborts = <Completer<void>>{};
  String? _applicationVersion;
  String? _webApiVersion;

  String? get applicationVersion => _applicationVersion;
  String? get webApiVersion => _webApiVersion;
  bool get isAuthenticated => !_disposed && _appMajor != null && _hasCookie;

  bool get _hasCookie =>
      _cookie != null &&
      (_cookieExpires == null || _now().isBefore(_cookieExpires!));

  Uri _uri(String endpoint, [Map<String, String>? query]) =>
      _http.baseUri.replace(
        path: '${_http.baseUri.path}/api/v2/$endpoint',
        queryParameters: query,
      );

  void _checkActive({bool authenticated = true}) {
    if (_disposed) throw MediaApiException('Connection is no longer active.');
    if (authenticated && !isAuthenticated) {
      throw MediaApiException('Sign in to qBittorrent again.', statusCode: 401);
    }
  }

  /// A login response is not connection evidence by itself. Both server and
  /// Web API versions must be read using the newly issued session cookie.
  Future<void> login() async {
    _checkActive(authenticated: false);
    if (_loggingIn) throw MediaApiException('Sign-in is already in progress.');
    _loggingIn = true;
    _clearSession();
    healthSession?.connecting();
    try {
      await _guard(() async {
        final login = http.Request('POST', _uri('auth/login'))
          ..bodyFields = {
            'username': _config.username,
            'password': _config.password,
          };
        final response = await _send(login, authenticated: false);
        if (!((response.statusCode == 200 && response.body.trim() == 'Ok.') ||
                response.statusCode == 204) ||
            !_hasCookie) {
          throw MediaApiException(
            'Could not sign in to qBittorrent.',
            statusCode: 401,
          );
        }
        final app = (await _send(
          http.Request('GET', _uri('app/version')),
          authenticated: false,
          requireCookie: true,
        )).body.trim();
        final api = (await _send(
          http.Request('GET', _uri('app/webapiVersion')),
          authenticated: false,
          requireCookie: true,
        )).body.trim();
        final appMatch = RegExp(r'^v?([45])\.\d+\.\d+(?:[a-zA-Z0-9.+-]*)$')
            .firstMatch(app);
        final apiMatch = RegExp(r'^2\.(\d+)\.\d+$').firstMatch(api);
        if (app.length > 64 ||
            api.length > 32 ||
            appMatch == null ||
            apiMatch == null) {
          throw MediaApiException(
            'Unsupported qBittorrent server or Web API version.',
          );
        }
        final major = int.parse(appMatch.group(1)!);
        final apiMinor = int.parse(apiMatch.group(1)!);
        // qBittorrent 5 renamed pause/resume in Web API 2.11. Do not guess a
        // mutation endpoint from inconsistent proxy/version responses.
        if ((major == 5) != (apiMinor >= 11)) {
          throw MediaApiException('Inconsistent qBittorrent Web API version.');
        }
        _checkActive(authenticated: false);
        _appMajor = major;
        _applicationVersion = app;
        _webApiVersion = api;
        healthSession?.readSucceeded();
      });
    } catch (_) {
      _clearSession();
      rethrow;
    } finally {
      _loggingIn = false;
    }
  }

  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on MediaApiException catch (error) {
      healthSession?.failed(switch (error.statusCode) {
        401 => HealthFailure.authentication,
        403 => HealthFailure.permission,
        final int status when status >= 500 => HealthFailure.server,
        _ => HealthFailure.invalidResponse,
      });
      rethrow;
    } on TimeoutException {
      healthSession?.failed(HealthFailure.timeout);
      throw MediaApiException(
        'qBittorrent did not respond in time. The action may not have completed.',
      );
    } on http.ClientException {
      healthSession?.failed(HealthFailure.transport);
      throw MediaApiException(
        'Could not reach the configured qBittorrent server.',
      );
    } on IOException {
      healthSession?.failed(HealthFailure.transport);
      throw MediaApiException(
        'Could not read the qBittorrent connection or selected file.',
      );
    } catch (_) {
      healthSession?.failed(HealthFailure.invalidResponse);
      throw MediaApiException('qBittorrent returned an invalid response.');
    }
  }

  Future<http.Response> _send(
    http.BaseRequest request, {
    bool authenticated = true,
    bool requireCookie = false,
  }) async {
    _checkActive(authenticated: authenticated);
    if (requireCookie && !_hasCookie) {
      throw MediaApiException('Sign in to qBittorrent again.', statusCode: 401);
    }
    request.headers['Origin'] = _http.baseUri.origin;
    request.headers['Referer'] = '${_http.baseUri}/';
    if (_hasCookie) {
      request.headers['Cookie'] = '${_cookie!.name}=${_cookie!.value}';
    }
    final generation = _sessionGeneration;
    final abort = Completer<void>();
    _requestAborts.add(abort);
    final transportRequest = _abortableRequest(request, abort.future);
    final http.Response response;
    try {
      response =
          await (() async {
            final streamed = await _http.send(transportRequest);
            if (!_disposed && generation == _sessionGeneration) {
              healthSession?.contact();
            }
            if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
              await streamed.stream.listen((_) {}).cancel();
              if ({401, 403}.contains(streamed.statusCode) &&
                  generation == _sessionGeneration) {
                _clearSession();
              }
              throw MediaApiException(
                'qBittorrent request failed (HTTP ${streamed.statusCode}).',
                statusCode: streamed.statusCode,
              );
            }
            final bytes = <int>[];
            await for (final chunk in streamed.stream) {
              if (bytes.length + chunk.length > 2 * 1024 * 1024) {
                throw MediaApiException('qBittorrent response is too large.');
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
              throw TimeoutException('qBittorrent request timed out.');
            },
          );
    } finally {
      _requestAborts.remove(abort);
      if (!abort.isCompleted) abort.complete();
    }
    _checkActive(authenticated: false);
    if (generation != _sessionGeneration) {
      throw MediaApiException('Sign in to qBittorrent again.', statusCode: 401);
    }
    _receiveCookie(response.headers['set-cookie']);
    if ((authenticated || requireCookie) && !_hasCookie) {
      throw MediaApiException('Sign in to qBittorrent again.', statusCode: 401);
    }
    return response;
  }

  void _receiveCookie(String? header) {
    if (header == null) return;
    if (header.length > 8192) {
      throw MediaApiException('Invalid qBittorrent session cookie.');
    }
    final candidates = <Cookie>[];
    // package:http joins duplicate response headers. Expires contains a comma
    // but is not followed by a cookie-name '=' pair.
    final parts = header.split(RegExp(r',(?=\s*[^\s,;=]+=)'));
    if (parts.length > 16) {
      throw MediaApiException('Invalid qBittorrent session cookie.');
    }
    for (final part in parts) {
      final name = part.trimLeft().split('=').first;
      if (name != 'SID' && !RegExp(r'^QBT_SID_\d+$').hasMatch(name)) continue;
      try {
        candidates.add(Cookie.fromSetCookieValue(part.trim()));
      } catch (_) {
        throw MediaApiException('Invalid qBittorrent session cookie.');
      }
    }
    if (candidates.isEmpty) return;
    if (candidates.length != 1) {
      throw MediaApiException('Ambiguous qBittorrent session cookie.');
    }
    final cookie = candidates.single;
    final domain = cookie.domain
        ?.replaceFirst(RegExp(r'^\.'), '')
        .toLowerCase();
    final path = cookie.path ?? '${_http.baseUri.path}/api/v2/auth';
    final apiPath = '${_http.baseUri.path}/api/v2';
    if ((domain != null && domain != _http.baseUri.host.toLowerCase()) ||
        !(apiPath == path ||
            apiPath.startsWith(path.endsWith('/') ? path : '$path/')) ||
        (cookie.secure && _http.baseUri.scheme != 'https') ||
        cookie.value.length > 1024 ||
        cookie.value.contains(RegExp(r'[\x00-\x20\x7f-\uffff";,\\]'))) {
      throw MediaApiException('Invalid qBittorrent session cookie scope.');
    }
    final expires = cookie.maxAge == null
        ? cookie.expires
        : _now().add(Duration(seconds: cookie.maxAge!));
    if (cookie.value.isEmpty || (expires != null && !expires.isAfter(_now()))) {
      _clearSession();
      return;
    }
    _cookie = cookie;
    _cookieExpires = expires;
  }

  Future<void> _mutate(
    String endpoint,
    Map<String, String> fields,
    Set<String> targets,
  ) async {
    _checkActive();
    if (_pendingMutations.any(targets.contains)) {
      throw MediaApiException(
        'An action for this torrent is already in progress.',
      );
    }
    _pendingMutations.addAll(targets);
    try {
      await _guard(() async {
        final response = await _send(
          http.Request('POST', _uri(endpoint))..bodyFields = fields,
        );
        _checkMutationBody(response);
      });
    } finally {
      _pendingMutations.removeAll(targets);
    }
  }

  void _checkMutationBody(http.Response response) {
    if (!{'', 'Ok.'}.contains(response.body.trim())) {
      throw MediaApiException('qBittorrent did not accept the action.');
    }
  }

  void _clearSession() {
    _sessionGeneration++;
    _cookie = null;
    _cookieExpires = null;
    _appMajor = null;
    _applicationVersion = null;
    _webApiVersion = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _clearSession();
    healthSession?.close();
    for (final abort in _requestAborts.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
    _requestAborts.clear();
    _http.close();
  }
}

class QbittorrentTorrents {
  QbittorrentTorrents(this._client);
  final QbittorrentClient _client;

  Future<List<TorrentInfo>> getTorrentsList({
    TorrentListOptions options = const TorrentListOptions(),
  }) => _client._guard(() async {
    _client._checkActive();
    final query = {
      for (final e in options.toJson().entries)
        if (e.value != null) e.key: '${e.value}',
    };
    if (_client._appMajor == 5) {
      if (query['filter'] == 'paused') query['filter'] = 'stopped';
      if (query['filter'] == 'resumed') query['filter'] = 'running';
    }
    final response = await _client._send(
      http.Request('GET', _client._uri('torrents/info', query)),
    );
    final decoded = decodeServerJson(response.body);
    if (decoded is! List || decoded.length > 10000) {
      throw MediaApiException('Invalid qBittorrent torrent list.');
    }
    final items = decoded
        .map((value) {
          final json = Map<String, dynamic>.from(value as Map);
          final state = json['state'];
          if (state is String &&
              !TorrentState.values.any((value) => value.name == state)) {
            json['state'] = 'unknown';
          }
          final item = TorrentInfo.fromJson(json);
          if (item.progress != null &&
              (!item.progress!.isFinite ||
                  item.progress! < 0 ||
                  item.progress! > 1)) {
            throw MediaApiException('Invalid qBittorrent torrent progress.');
          }
          return item;
        })
        .toList(growable: false);
    _client.healthSession?.readSucceeded();
    return items;
  });

  Set<String> _hashes(Torrents torrents) {
    final hashes = torrents.toRequestString().split('|').toSet();
    if (hashes.isEmpty ||
        hashes.length > 50 ||
        hashes.any(
          (hash) =>
              !RegExp(r'^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$').hasMatch(hash),
        )) {
      throw MediaApiException(
        'Select specific valid torrents for this action.',
      );
    }
    return hashes.map((hash) => hash.toLowerCase()).toSet();
  }

  Future<void> pauseTorrents({required Torrents torrents}) =>
      _act(_client._appMajor == 5 ? 'stop' : 'pause', torrents);
  Future<void> resumeTorrents({required Torrents torrents}) =>
      _act(_client._appMajor == 5 ? 'start' : 'resume', torrents);
  Future<void> deleteTorrents({
    required Torrents torrents,
    bool deleteFiles = false,
  }) => _act('delete', torrents, {'deleteFiles': '$deleteFiles'});

  Future<void> _act(
    String action,
    Torrents torrents, [
    Map<String, String> fields = const {},
  ]) async {
    final hashes = _hashes(torrents);
    await _client._mutate('torrents/$action', {
      'hashes': hashes.join('|'),
      ...fields,
    }, hashes);
  }

  Future<void> addNewTorrents({required NewTorrents torrents}) async {
    _client._checkActive();
    const key = 'add';
    if (!_client._pendingMutations.add(key)) {
      throw MediaApiException('Adding a torrent is already in progress.');
    }
    try {
      await _client._guard(() async {
        // This obsolete SDK field could cause credentials to be forwarded by
        // the server to a remote download URL. The app never requests it.
        if (torrents.cookie != null) {
          throw MediaApiException('Remote download cookies are not supported.');
        }
        final request = http.MultipartRequest(
          'POST',
          _client._uri('torrents/add'),
        );
        final fields = torrents.toFormData()
          ..remove('torrents')
          ..remove('urls');
        if (_client._appMajor == 5 && fields.containsKey('paused')) {
          fields['stopped'] = fields.remove('paused');
        }
        for (final entry in fields.entries) {
          final value = '${entry.value}';
          if (value.length > 4096 ||
              value.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
              (entry.value is double && !(entry.value as double).isFinite)) {
            throw MediaApiException('Invalid torrent options.');
          }
          request.fields[entry.key] = value;
        }
        if (torrents.urls != null) {
          final urls = torrents.urls!;
          if (urls.isEmpty || urls.length > 20) {
            throw MediaApiException('Select between 1 and 20 torrents.');
          }
          for (final url in urls) {
            final uri = Uri.tryParse(url);
            if (url.length > 8192 ||
                url.contains(RegExp(r'[\s\x00-\x1f\x7f]')) ||
                uri == null ||
                uri.userInfo.isNotEmpty ||
                !(({'http', 'https'}.contains(uri.scheme) &&
                        uri.host.isNotEmpty) ||
                    (uri.scheme == 'magnet' &&
                        (uri.queryParametersAll['xt'] ?? []).any(
                          (xt) =>
                              xt.startsWith('urn:btih:') ||
                              xt.startsWith('urn:btmh:'),
                        )))) {
              throw MediaApiException('Enter a valid magnet or torrent URL.');
            }
          }
          request.fields['urls'] = urls.join('\n');
        } else {
          final files = <FileBytes>[...?torrents.bytes];
          var total = files.fold<int>(
            0,
            (sum, file) => sum + file.bytes.length,
          );
          if (files.length + (torrents.files?.length ?? 0) > 20) {
            throw MediaApiException('Select up to 20 torrent files.');
          }
          for (final file in torrents.files ?? <File>[]) {
            final length = await file.length();
            if (total + length > 10 * 1024 * 1024) {
              throw MediaApiException('Torrent files exceed 10 MiB.');
            }
            final bytes = <int>[];
            await for (final chunk in file.openRead()) {
              if (total + bytes.length + chunk.length > 10 * 1024 * 1024) {
                throw MediaApiException('Torrent files exceed 10 MiB.');
              }
              bytes.addAll(chunk);
            }
            total += bytes.length;
            files.add(
              FileBytes(
                filename: file.uri.pathSegments.last,
                bytes: Uint8List.fromList(bytes),
              ),
            );
          }
          if (files.isEmpty || files.length > 20 || total > 10 * 1024 * 1024) {
            throw MediaApiException(
              'Select up to 20 torrent files, at most 10 MiB.',
            );
          }
          for (final file in files) {
            final name = file.filename;
            if (file.bytes.isEmpty ||
                name.length > 255 ||
                !name.toLowerCase().endsWith('.torrent') ||
                name.contains(RegExp(r'[/\\\x00-\x1f\x7f"]'))) {
              throw MediaApiException('Select a valid .torrent file.');
            }
            request.files.add(
              http.MultipartFile.fromBytes(
                'torrents',
                file.bytes,
                filename: name,
              ),
            );
          }
        }
        final response = await _client._send(request);
        _client._checkMutationBody(response);
      });
    } finally {
      _client._pendingMutations.remove(key);
    }
  }
}

// IOClient supports Abortable for both request upload and response download.
// Keep the timeout fallback for injected/platform clients without this support.
http.BaseRequest _abortableRequest(
  http.BaseRequest source,
  Future<void> abort,
) {
  final http.BaseRequest request;
  if (source is http.MultipartRequest) {
    request = _AbortableMultipartRequest(source.method, source.url, abort)
      ..fields.addAll(source.fields)
      ..files.addAll(source.files);
  } else if (source is http.Request) {
    request = http.AbortableRequest(
      source.method,
      source.url,
      abortTrigger: abort,
    )..bodyBytes = source.bodyBytes;
  } else {
    throw MediaApiException('Unsupported qBittorrent request.');
  }
  request.headers.addAll(source.headers);
  request.persistentConnection = source.persistentConnection;
  return request;
}

class _AbortableMultipartRequest extends http.MultipartRequest
    with http.Abortable {
  _AbortableMultipartRequest(super.method, super.url, this.abortTrigger);
  @override
  final Future<void> abortTrigger;
}
