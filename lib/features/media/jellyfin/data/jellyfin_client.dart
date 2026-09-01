import 'dart:convert';

import 'package:http/http.dart' as http;

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
    : _client = httpClient ?? http.Client();

  final JellyfinConfig config;
  final http.Client _client;

  static const _clientName = 'Larenor';
  static const _clientVersion = '1.0.0';

  static String _authHeader({required String deviceId, String? token}) {
    final tokenPart = token != null ? ', Token="$token"' : '';
    return 'MediaBrowser Client="$_clientName", Device="Tablet", '
        'DeviceId="$deviceId", Version="$_clientVersion"$tokenPart';
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'X-Emby-Authorization': _authHeader(
      deviceId: config.deviceId,
      token: config.accessToken,
    ),
  };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final uri = Uri.parse('${config.baseUrl}$path');
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
    final client = httpClient ?? http.Client();
    final response = await client
        .post(
          Uri.parse('$baseUrl/Users/AuthenticateByName'),
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

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final accessToken = body['AccessToken'] as String?;
    final userId = (body['User'] as Map<String, dynamic>?)?['Id'] as String?;
    if (accessToken == null || userId == null) {
      throw MediaApiException('Unexpected login response.');
    }

    return JellyfinConfig(
      baseUrl: baseUrl,
      userId: userId,
      accessToken: accessToken,
      deviceId: deviceId,
    );
  }

  Future<List<JellyfinItem>> getResumeItems() async {
    final response = await _client.get(
      _uri('/Users/${config.userId}/Items/Resume', {'Limit': 20}),
      headers: _headers,
    );
    return _parseItemsEnvelope(response);
  }

  Future<List<JellyfinItem>> getLatestItems() async {
    final response = await _client.get(
      _uri('/Users/${config.userId}/Items/Latest', {'Limit': 20}),
      headers: _headers,
    );
    _checkOk(response);
    return _parseItemList(jsonDecode(response.body) as List<dynamic>);
  }

  Future<List<JellyfinItem>> getLibraries() async {
    final response = await _client.get(
      _uri('/Users/${config.userId}/Views'),
      headers: _headers,
    );
    return _parseItemsEnvelope(response);
  }

  Future<List<JellyfinItem>> getItemsInLibrary(String parentId) async {
    final response = await _client.get(
      _uri('/Users/${config.userId}/Items', {
        'ParentId': parentId,
        'SortBy': 'SortName',
      }),
      headers: _headers,
    );
    return _parseItemsEnvelope(response);
  }

  String imageUrl(String itemId, {String type = 'Primary'}) {
    return '${config.baseUrl}/Items/$itemId/Images/$type';
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
      _uri('/Items/$itemId/PlaybackInfo'),
      headers: _headers,
      body: jsonEncode({
        'UserId': config.userId,
        'DeviceProfile': buildJellyfinDeviceProfile(),
        'MaxStreamingBitrate': ?maxStreamingBitrate,
      }),
    );
    _checkOk(response);

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final playSessionId = body['PlaySessionId'] as String;
    final mediaSources = body['MediaSources'] as List<dynamic>? ?? [];
    if (mediaSources.isEmpty) {
      throw MediaApiException('No playable media source for this item.');
    }

    final source = mediaSources.first as Map<String, dynamic>;
    final mediaSourceId = source['Id'] as String;
    final transcodingUrl = source['TranscodingUrl'] as String?;

    final streamUrl = transcodingUrl != null
        ? '${config.baseUrl}$transcodingUrl'
        : '${config.baseUrl}/Videos/$itemId/stream'
              '?static=true&mediaSourceId=$mediaSourceId'
              '&api_key=${config.accessToken}';

    return JellyfinPlaybackSource(
      streamUrl: streamUrl,
      mediaSourceId: mediaSourceId,
      playSessionId: playSessionId,
      isTranscoding: transcodingUrl != null,
    );
  }

  Future<void> reportPlaybackStart({
    required String itemId,
    required JellyfinPlaybackSource source,
  }) => _postSession('/Sessions/Playing', itemId, source, positionTicks: 0);

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
    final body = jsonDecode(response.body) as Map<String, dynamic>;
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
