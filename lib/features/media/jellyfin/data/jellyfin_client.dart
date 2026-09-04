import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../shared/network/server_bound_client.dart';

import '../../data/media_api_exception.dart';
import 'jellyfin_config.dart';
import 'jellyfin_device_profile.dart';
import 'models/jellyfin_item.dart';

class JellyfinPlaybackSource {
  const JellyfinPlaybackSource({
    required this.streamUrl,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.isTranscoding,
  });

  final String streamUrl;
  final String mediaSourceId;
  final String playSessionId;
  final bool isTranscoding;
}

/// Thin hand-rolled client over Jellyfin's REST API — a Dart package
/// (`jellyfin_dart`) exists but gave inconsistent, unverifiable examples of
/// its own API surface, so this mirrors the same "hand-roll for control"
/// approach already used for the Home Assistant client.
class JellyfinClient {
  JellyfinClient({required this.config, http.Client? httpClient})
    : _client = ServerBoundClient(baseUrl: config.baseUrl, inner: httpClient),
      _baseUri = parseServerUrl(config.baseUrl);

  final JellyfinConfig config;
  final http.Client _client;
  final Uri _baseUri;

  static const _clientName = 'Larenor';
  static const _clientVersion = '1.0.0';

  static String _authHeader({required String deviceId, String? token}) {
    String quote(String value) {
      if (value.contains(RegExp(r'[\r\n]'))) {
        throw const FormatException('Invalid authentication header value.');
      }
      return value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    }

    final tokenPart = token != null ? ', Token="${quote(token)}"' : '';
    return 'MediaBrowser Client="$_clientName", Device="Tablet", '
        'DeviceId="${quote(deviceId)}", Version="$_clientVersion"$tokenPart';
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'X-Emby-Authorization': _authHeader(
      deviceId: config.deviceId,
      token: config.accessToken,
    ),
  };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final uri = Uri.parse('$_baseUri$path');
    if (query == null) return uri;
    return uri.replace(
      queryParameters: query.map((key, value) => MapEntry(key, '$value')),
    );
  }

  static Future<JellyfinConfig> login({
    required String baseUrl,
    required String username,
    required String password,
    required String deviceId,
    http.Client? httpClient,
  }) async {
    final server = parseServerUrl(baseUrl);
    final client = ServerBoundClient(
      baseUrl: server.toString(),
      inner: httpClient,
    );
    try {
      final response = await client
          .post(
            Uri.parse('$server/Users/AuthenticateByName'),
            headers: {
              'Content-Type': 'application/json',
              'X-Emby-Authorization': _authHeader(deviceId: deviceId),
            },
            body: jsonEncode({'Username': username, 'Pw': password}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw MediaApiException('Login failed (${response.statusCode}).');
      }

      final body = decodeServerJson(response.body) as Map<String, dynamic>;
      final accessToken = body['AccessToken'] as String?;
      final userId = (body['User'] as Map<String, dynamic>?)?['Id'] as String?;
      if (accessToken == null || userId == null) {
        throw MediaApiException('Unexpected login response.');
      }

      return JellyfinConfig(
        baseUrl: server.toString(),
        userId: userId,
        accessToken: accessToken,
        deviceId: deviceId,
      );
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Fields Jellyfin leaves out of list responses unless asked for.
  /// `ProviderIds` is the important one — without it a library item can't
  /// be matched against the same title in Jellyseerr, Radarr or Sonarr.
  static const _itemFields = 'ProviderIds,Overview,Genres';

  Future<List<JellyfinItem>> getResumeItems() async {
    final response = await _client.get(
      _uri('/Users/${Uri.encodeComponent(config.userId)}/Items/Resume', {
        'Limit': 20,
        'Fields': _itemFields,
      }),
      headers: _headers,
    );
    return _parseItemsEnvelope(response);
  }

  Future<List<JellyfinItem>> getLatestItems() async {
    final response = await _client.get(
      _uri('/Users/${Uri.encodeComponent(config.userId)}/Items/Latest', {
        'Limit': 20,
        'Fields': _itemFields,
      }),
      headers: _headers,
    );
    _checkOk(response);
    return _parseItemList(decodeServerJson(response.body) as List<dynamic>);
  }

  Future<List<JellyfinItem>> getLibraries() async {
    final response = await _client.get(
      _uri('/Users/${Uri.encodeComponent(config.userId)}/Views'),
      headers: _headers,
    );
    return _parseItemsEnvelope(response);
  }

  Future<List<JellyfinItem>> getItemsInLibrary(String parentId) async {
    final response = await _client.get(
      _uri('/Users/${Uri.encodeComponent(config.userId)}/Items', {
        'ParentId': parentId,
        'SortBy': 'SortName',
        'Fields': _itemFields,
      }),
      headers: _headers,
    );
    return _parseItemsEnvelope(response);
  }

  /// Every film and series in the library, flattened. Used to build the
  /// media hub's availability index, so `Recursive=true` and the item
  /// types are pinned to the two kinds the hub deals in.
  Future<List<JellyfinItem>> getAllMoviesAndSeries({int limit = 2000}) async {
    if (limit < 1) throw ArgumentError.value(limit, 'limit');
    final items = <JellyfinItem>[];
    final seen = <String>{};
    var startIndex = 0;
    while (true) {
      final response = await _client
          .get(
            _uri('/Users/${Uri.encodeComponent(config.userId)}/Items', {
              'Recursive': true,
              'IncludeItemTypes': 'Movie,Series',
              'SortBy': 'SortName',
              'StartIndex': startIndex,
              'Limit': limit,
              'Fields': _itemFields,
            }),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));
      _checkOk(response);
      final body = decodeServerJson(response.body) as Map<String, dynamic>;
      final page = _parseItemList(body['Items'] as List<dynamic>? ?? []);
      final unique = page.where((item) => seen.add(item.id)).toList();
      items.addAll(unique);
      startIndex += page.length;
      final total = (body['TotalRecordCount'] as num?)?.toInt();
      // Guard against a server/proxy that ignores the pagination offset.
      if (unique.isEmpty ||
          (total != null ? startIndex >= total : page.length < limit)) {
        break;
      }
    }
    return items;
  }

  Future<List<JellyfinItem>> getSeasons(String seriesId) async {
    final response = await _client
        .get(
          _uri('/Shows/${Uri.encodeComponent(seriesId)}/Seasons', {
            'UserId': config.userId,
            'IsMissing': false,
            'Fields': _itemFields,
          }),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    return _parseItemsEnvelope(response);
  }

  Future<List<JellyfinItem>> getEpisodes(
    String seriesId, {
    String? seasonId,
  }) async {
    final response = await _client
        .get(
          _uri('/Shows/${Uri.encodeComponent(seriesId)}/Episodes', {
            'UserId': config.userId,
            'SeasonId': ?seasonId,
            'IsMissing': false,
            'Fields': _itemFields,
          }),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    return _parseItemsEnvelope(response);
  }

  Future<List<JellyfinItem>> search(String term, {int limit = 40}) async {
    if (term.trim().isEmpty) return const [];
    final response = await _client.get(
      _uri('/Users/${Uri.encodeComponent(config.userId)}/Items', {
        'searchTerm': term,
        'Recursive': true,
        'IncludeItemTypes': 'Movie,Series',
        'Limit': limit,
        'Fields': _itemFields,
      }),
      headers: _headers,
    );
    return _parseItemsEnvelope(response);
  }

  Future<JellyfinItem> getItem(String itemId) async {
    final response = await _client.get(
      _uri(
        '/Users/${Uri.encodeComponent(config.userId)}/Items/${Uri.encodeComponent(itemId)}',
        {'Fields': _itemFields},
      ),
      headers: _headers,
    );
    _checkOk(response);
    return JellyfinItem.fromJson(
      decodeServerJson(response.body) as Map<String, dynamic>,
    );
  }

  /// [tag] is the matching entry from [JellyfinItem.imageTags]; passing it
  /// makes the URL content-addressed, so the on-disk image cache can hold
  /// a poster indefinitely and still pick up genuine artwork changes.
  String imageUrl(String itemId, {String type = 'Primary', String? tag}) {
    return _uri(
      '/Items/${Uri.encodeComponent(itemId)}/Images/${Uri.encodeComponent(type)}',
      tag == null ? null : {'tag': tag},
    ).toString();
  }

  /// [maxStreamingBitrate] caps the stream at a given bits-per-second
  /// ceiling (a manual "quality" selection) — when the source exceeds it,
  /// Jellyfin transcodes down to fit; when it doesn't, Direct Play
  /// continues exactly as with no cap at all, so picking a lower quality
  /// never makes an already-smaller file worse.
  Future<JellyfinPlaybackSource> getPlaybackInfo(
    String itemId, {
    int? maxStreamingBitrate,
  }) async {
    final response = await _client.post(
      _uri('/Items/${Uri.encodeComponent(itemId)}/PlaybackInfo'),
      headers: _headers,
      body: jsonEncode({
        'UserId': config.userId,
        'DeviceProfile': buildJellyfinDeviceProfile(),
        'MaxStreamingBitrate': ?maxStreamingBitrate,
      }),
    );
    _checkOk(response);

    final body = decodeServerJson(response.body) as Map<String, dynamic>;
    final playSessionId = body['PlaySessionId'] as String;
    final mediaSources = body['MediaSources'] as List<dynamic>? ?? [];
    if (mediaSources.isEmpty) {
      throw MediaApiException('No playable media source for this item.');
    }

    final sources = mediaSources.cast<Map<String, dynamic>>();
    final source = sources.firstWhere(
      (source) => source['SupportsDirectPlay'] == true,
      orElse: () => sources.first,
    );
    final mediaSourceId = source['Id'] as String;
    final transcodingUrl = source['SupportsDirectPlay'] == true
        ? null
        : source['TranscodingUrl'] as String?;

    final streamUrl = transcodingUrl != null
        ? _playbackUri(transcodingUrl).toString()
        : _uri('/Videos/${Uri.encodeComponent(itemId)}/stream', {
            'static': true,
            'mediaSourceId': mediaSourceId,
            'api_key': config.accessToken,
          }).toString();

    return JellyfinPlaybackSource(
      streamUrl: streamUrl,
      mediaSourceId: mediaSourceId,
      playSessionId: playSessionId,
      isTranscoding: transcodingUrl != null,
    );
  }

  Uri _playbackUri(String value) {
    final provided = Uri.tryParse(value);
    if (provided == null ||
        value.contains('\\') ||
        RegExp(
          r'(^|/)(\.|%2e){1,2}(/|$)',
          caseSensitive: false,
        ).hasMatch(value.split(RegExp(r'[?#]')).first) ||
        provided.path.isEmpty) {
      throw MediaApiException('Server returned an invalid playback URL.');
    }
    final Uri resolved;
    if (provided.hasScheme || provided.hasAuthority) {
      resolved = provided;
    } else if (provided.path.startsWith('/')) {
      // Jellyfin versions/proxies may supply a root-relative path with or
      // without the configured URL prefix. Preserve it exactly once.
      final prefix = _baseUri.path;
      resolved = prefix.isNotEmpty && provided.path.startsWith('$prefix/')
          ? _baseUri.resolveUri(provided)
          : Uri.parse('$_baseUri$provided');
    } else {
      resolved = Uri.parse('$_baseUri/').resolveUri(provided);
    }
    if (!isWithinServer(_baseUri, resolved)) {
      throw MediaApiException('Playback URL is outside the configured server.');
    }
    return resolved;
  }

  Future<void> reportPlaybackStart({
    required String itemId,
    required JellyfinPlaybackSource source,
    Duration position = Duration.zero,
  }) => _postSession(
    '/Sessions/Playing',
    itemId,
    source,
    positionTicks: _ticksFrom(position),
  );

  Future<void> reportPlaybackProgress({
    required String itemId,
    required JellyfinPlaybackSource source,
    required Duration position,
    bool isPaused = false,
  }) => _postSession(
    '/Sessions/Playing/Progress',
    itemId,
    source,
    positionTicks: _ticksFrom(position),
    isPaused: isPaused,
  );

  Future<void> reportPlaybackStopped({
    required String itemId,
    required JellyfinPlaybackSource source,
    required Duration position,
  }) => _postSession(
    '/Sessions/Playing/Stopped',
    itemId,
    source,
    positionTicks: _ticksFrom(position),
  );

  Future<void> _postSession(
    String path,
    String itemId,
    JellyfinPlaybackSource source, {
    required int positionTicks,
    bool isPaused = false,
  }) async {
    try {
      await _client.post(
        _uri(path),
        headers: _headers,
        body: jsonEncode({
          'ItemId': itemId,
          'MediaSourceId': source.mediaSourceId,
          'PlaySessionId': source.playSessionId,
          'PositionTicks': positionTicks,
          'IsPaused': isPaused,
          'CanSeek': true,
        }),
      );
    } catch (_) {
      // Best-effort — a reporting failure shouldn't interrupt playback.
    }
  }

  /// 1 tick = 100ns, i.e. 10,000,000 ticks per second.
  int _ticksFrom(Duration duration) => duration.inMicroseconds * 10;

  Future<List<JellyfinItem>> _parseItemsEnvelope(http.Response response) {
    _checkOk(response);
    final body = decodeServerJson(response.body) as Map<String, dynamic>;
    return Future.value(
      _parseItemList(body['Items'] as List<dynamic>? ?? const []),
    );
  }

  List<JellyfinItem> _parseItemList(List<dynamic> raw) {
    return raw
        .map((e) => JellyfinItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  void _checkOk(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MediaApiException('Request failed (${response.statusCode}).');
    }
  }

  void dispose() => _client.close();
}
