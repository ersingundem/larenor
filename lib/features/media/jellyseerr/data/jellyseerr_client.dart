import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../data/media_api_exception.dart';
import 'jellyseerr_config.dart';
import 'models/jellyseerr_request_item.dart';
import 'models/jellyseerr_result.dart';

/// Thin hand-rolled client over Jellyseerr's REST API (`/api/v1/*`),
/// verified against Jellyseerr's own route/model source (not guessed) —
/// `X-Api-Key` header auth, camelCase response fields.
class JellyseerrClient {
  JellyseerrClient({required this.config, http.Client? httpClient})
    : _client = httpClient ?? http.Client();

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

  String? posterUrl(String? posterPath) {
    if (posterPath == null) return null;
    return 'https://image.tmdb.org/t/p/w300$posterPath';
  }

  Future<List<JellyseerrResult>> search(String query) async {
    final response = await _client
        .get(_uri('/search', {'query': query}), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
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
            'seasons': ?seasons,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw MediaApiException(
        'Request failed (${response.statusCode}): ${response.body}',
      );
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
    final body = jsonDecode(response.body) as Map<String, dynamic>;
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
