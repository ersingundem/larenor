import 'package:http/http.dart' as http;

import '../../../../shared/network/server_bound_client.dart';

import '../../data/media_api_exception.dart';
import 'bazarr_config.dart';
import 'models/bazarr_wanted_item.dart';

/// Thin hand-rolled client over Bazarr's REST API (`/api/*`), verified
/// against Bazarr's own `bazarr/api/utils.py` auth decorator and the
/// movies/episodes wanted+subtitles route source (not guessed) —
/// `X-API-KEY` header, `PATCH` triggers a subtitle search+download.
class BazarrClient {
  BazarrClient({required this.config, http.Client? httpClient})
    : _client = ServerBoundClient(baseUrl: config.baseUrl, inner: httpClient);

  final BazarrConfig config;
  final http.Client _client;

  Map<String, String> get _headers => {'X-API-KEY': config.apiKey};

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final uri = Uri.parse('${config.baseUrl}/api$path');
    if (query == null) return uri;
    return uri.replace(
      queryParameters: query.map((key, value) => MapEntry(key, '$value')),
    );
  }

  Future<void> checkConnection() async {
    final response = await _client
        .get(_uri('/system/status'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw MediaApiException('Invalid server URL or API key.');
    }
  }

  Future<List<BazarrWantedItem>> getMissingMovieSubtitles() =>
      _getWanted('/movies/wanted');

  Future<List<BazarrWantedItem>> getMissingEpisodeSubtitles() =>
      _getWanted('/episodes/wanted');

  Future<List<BazarrWantedItem>> _getWanted(String path) async {
    final response = await _client
        .get(_uri(path, {'start': 0, 'length': 50}), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final decoded = decodeServerJson(response.body);
    final list = decoded is Map<String, dynamic>
        ? (decoded['data'] as List<dynamic>? ?? const [])
        : decoded as List<dynamic>;
    return list
        .map((e) => BazarrWantedItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> searchMovieSubtitle({
    required int radarrId,
    required String language,
    bool forced = false,
    bool hi = false,
  }) => _patch('/movies/subtitles', {
    'radarrid': '$radarrId',
    'language': language,
    'forced': '$forced',
    'hi': '$hi',
  });

  Future<void> searchEpisodeSubtitle({
    required int seriesId,
    required int episodeId,
    required String language,
    bool forced = false,
    bool hi = false,
  }) => _patch('/episodes/subtitles', {
    'seriesid': '$seriesId',
    'episodeid': '$episodeId',
    'language': language,
    'forced': '$forced',
    'hi': '$hi',
  });

  Future<void> _patch(String path, Map<String, String> body) async {
    final response = await _client
        .patch(_uri(path), headers: _headers, body: body)
        .timeout(const Duration(seconds: 30));
    _checkOk(response);
  }

  void _checkOk(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MediaApiException('Request failed (${response.statusCode}).');
    }
  }

  void dispose() => _client.close();
}
