import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../shared/network/server_bound_client.dart';

import '../../data/media_api_exception.dart';
import 'jellyseerr_config.dart';
import 'models/jellyseerr_request_item.dart';
import 'models/jellyseerr_result.dart';

/// Thin hand-rolled client over Jellyseerr's REST API (`/api/v1/*`),
/// verified against Jellyseerr's own route/model source (not guessed) —
/// `X-Api-Key` header auth, camelCase response fields.
class JellyseerrClient {
  JellyseerrClient({required this.config, http.Client? httpClient})
    : _client = ServerBoundClient(baseUrl: config.baseUrl, inner: httpClient);

  final JellyseerrConfig config;
  final http.Client _client;

  Map<String, String> get _headers => {
    'X-Api-Key': config.apiKey,
    'Content-Type': 'application/json',
  };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final uri = Uri.parse('${config.baseUrl}/api/v1$path');
    if (query == null) return uri;
    return uri.replace(
      queryParameters: query.map((key, value) => MapEntry(key, '$value')),
    );
  }

  Future<void> checkConnection() async {
    final response = await _client
        .get(_uri('/auth/me'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw MediaApiException('Invalid server URL or API key.');
    }
  }

  String? posterUrl(String? posterPath, {String size = 'w300'}) {
    if (posterPath == null) return null;
    return 'https://image.tmdb.org/t/p/$size$posterPath';
  }

  String? backdropUrl(String? backdropPath, {String size = 'w1280'}) {
    if (backdropPath == null) return null;
    return 'https://image.tmdb.org/t/p/$size$backdropPath';
  }

  /// Trending across both films and TV — the closest thing Jellyseerr
  /// offers to a "what's popular right now" row.
  Future<List<JellyseerrResult>> discoverTrending({int page = 1}) =>
      _discover('/discover/trending', page: page);

  Future<List<JellyseerrResult>> discoverMovies({int page = 1}) =>
      _discover('/discover/movies', page: page);

  Future<List<JellyseerrResult>> discoverTv({int page = 1}) =>
      _discover('/discover/tv', page: page);

  /// The discover endpoints return the same paged `{results: [...]}`
  /// envelope as search, except `/discover/movies` and `/discover/tv`
  /// omit `mediaType` (it's implied by the route), so it's filled in here
  /// — otherwise those results couldn't be told apart downstream.
  Future<List<JellyseerrResult>> _discover(
    String path, {
    required int page,
  }) async {
    final response = await _client
        .get(_uri(path, {'page': page}), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final body = decodeServerJson(response.body) as Map<String, dynamic>;
    final results = body['results'] as List<dynamic>? ?? [];

    final implied = switch (path) {
      '/discover/movies' => 'movie',
      '/discover/tv' => 'tv',
      _ => null,
    };

    return results
        .map((e) => e as Map<String, dynamic>)
        .where((e) {
          final type = e['mediaType'] as String? ?? implied;
          return type == 'movie' || type == 'tv';
        })
        .map(
          (e) => JellyseerrResult.fromJson({
            ...e,
            if (e['mediaType'] == null && implied != null) 'mediaType': implied,
          }),
        )
        .toList();
  }

  Future<List<JellyseerrResult>> search(String query) async {
    final response = await _client
        .get(_uri('/search', {'query': query}), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final body = decodeServerJson(response.body) as Map<String, dynamic>;
    final results = body['results'] as List<dynamic>? ?? [];
    return results
        .where((e) {
          final type = (e as Map<String, dynamic>)['mediaType'] as String?;
          return type == 'movie' || type == 'tv';
        })
        .map((e) => JellyseerrResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> requestMedia({
    required String mediaType,
    required int mediaId,
    List<int>? seasons,
  }) async {
    final response = await _client
        .post(
          _uri('/request'),
          headers: _headers,
          body: jsonEncode({
            'mediaType': mediaType,
            'mediaId': mediaId,
            if (mediaType == 'tv') 'seasons': seasons ?? 'all',
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw MediaApiException('Request failed (${response.statusCode}).');
    }
  }

  Future<List<JellyseerrRequestItem>> myRequests() async {
    final response = await _client
        .get(
          _uri('/request', {'take': 50, 'filter': 'all', 'sort': 'added'}),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final body = decodeServerJson(response.body) as Map<String, dynamic>;
    final results = body['results'] as List<dynamic>? ?? [];
    return results
        .map((e) => JellyseerrRequestItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  void _checkOk(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MediaApiException('Request failed (${response.statusCode}).');
    }
  }

  void dispose() => _client.close();
}
