import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../data/media_api_exception.dart';
import 'arr_config.dart';
import 'models/arr_calendar_item.dart';
import 'models/arr_lookup_result.dart';
import 'models/arr_picker_options.dart';
import 'models/arr_queue_item.dart';

/// Sonarr and Radarr are the same underlying app family — identical REST
/// API v3 shape (`X-Api-Key` header, camelCase JSON — verified against
/// Sonarr's own generated API client docs and the arrapi Python library's
/// request-building code, not guessed), differing only in resource name
/// (`series` vs `movie`) and lookup id field (`tvdbId` vs `tmdbId`). One
/// parameterized client covers both instead of duplicating it.
class ArrClient {
  ArrClient({
    required this.config,
    required this.resourcePath,
    required this.idFieldName,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client();

  final ArrConfig config;

  /// `'series'` for Sonarr, `'movie'` for Radarr.
  final String resourcePath;

  /// `'tvdbId'` for Sonarr, `'tmdbId'` for Radarr.
  final String idFieldName;

  final http.Client _client;

  Map<String, String> get _headers => {
    'X-Api-Key': config.apiKey,
    'Content-Type': 'application/json',
  };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final uri = Uri.parse('${config.baseUrl}/api/v3$path');
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

  Future<List<ArrLookupResult>> lookup(String term) async {
    final response = await _client
        .get(_uri('/$resourcePath/lookup', {'term': term}), headers: _headers)
        .timeout(const Duration(seconds: 20));
    _checkOk(response);
    final decoded = jsonDecode(response.body) as List<dynamic>;
    return decoded
        .map(
          (e) => ArrLookupResult.fromJson(
            e as Map<String, dynamic>,
            idFieldName: idFieldName,
          ),
        )
        .toList();
  }

  Future<List<ArrQualityProfile>> getQualityProfiles() async {
    final response = await _client
        .get(_uri('/qualityprofile'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final decoded = jsonDecode(response.body) as List<dynamic>;
    return decoded
        .map((e) => ArrQualityProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ArrRootFolder>> getRootFolders() async {
    final response = await _client
        .get(_uri('/rootfolder'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final decoded = jsonDecode(response.body) as List<dynamic>;
    return decoded
        .map((e) => ArrRootFolder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Adds [result] to the library: takes the full looked-up object and
  /// merges in the fields the add endpoint needs, matching what every
  /// *arr client does (Sonarr/Radarr want the whole metadata object back,
  /// not just a handful of ids).
  Future<void> add({
    required ArrLookupResult result,
    required int qualityProfileId,
    required String rootFolderPath,
    bool searchOnAdd = true,
  }) async {
    final body = {
      ...result.raw,
      'qualityProfileId': qualityProfileId,
      'rootFolderPath': rootFolderPath,
      'monitored': true,
      'addOptions': resourcePath == 'series'
          ? {'searchForMissingEpisodes': searchOnAdd, 'monitor': 'all'}
          : {'searchForMovie': searchOnAdd},
    };

    final response = await _client
        .post(_uri('/$resourcePath'), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw MediaApiException(
        'Add failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<List<ArrQueueItem>> getQueue() async {
    final response = await _client
        .get(
          _uri('/queue', {
            'pageSize': 50,
            'includeSeries': true,
            'includeMovie': true,
          }),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final body = jsonDecode(response.body);
    final records = body is Map<String, dynamic>
        ? (body['records'] as List<dynamic>? ?? const [])
        : body as List<dynamic>;
    return records
        .map((e) => ArrQueueItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ArrCalendarItem>> getCalendar({int days = 14}) async {
    final start = DateTime.now();
    final end = start.add(Duration(days: days));
    final response = await _client
        .get(
          _uri('/calendar', {
            'start': start.toIso8601String(),
            'end': end.toIso8601String(),
            'includeSeries': true,
          }),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final decoded = jsonDecode(response.body) as List<dynamic>;
    return decoded
        .map((e) => ArrCalendarItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  void _checkOk(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MediaApiException('Request failed (${response.statusCode}).');
    }
  }

  void dispose() => _client.close();
}
