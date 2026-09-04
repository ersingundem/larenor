import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../shared/network/server_bound_client.dart';

import '../../data/media_api_exception.dart';
import 'arr_config.dart';
import 'models/arr_calendar_item.dart';
import 'models/arr_library_item.dart';
import 'models/arr_lookup_result.dart';
import 'models/arr_picker_options.dart';
import 'models/arr_queue_item.dart';

/// Sonarr, Radarr, Lidarr, and Readarr are the same underlying "Servarr"
/// app family — identical REST shape (`X-Api-Key` header, camelCase JSON
/// — verified against Sonarr's own generated API client docs, the arrapi
/// Python library's request-building code, and Lidarr/Readarr's own
/// controller source, not guessed), differing only in API version prefix
/// (`v3` for Sonarr/Radarr, `v1` for Lidarr/Readarr), resource name
/// (`series`/`movie`/`artist`/`author`), and lookup id field (`tvdbId`/
/// `tmdbId`/`foreignArtistId`/`foreignAuthorId`). One parameterized client
/// covers all four instead of duplicating it.
class ArrClient {
  ArrClient({
    required this.config,
    required this.resourcePath,
    required this.idFieldName,
    this.apiVersion = 'v3',
    http.Client? httpClient,
  }) : _client = ServerBoundClient(baseUrl: config.baseUrl, inner: httpClient);

  final ArrConfig config;

  /// `'series'` (Sonarr), `'movie'` (Radarr), `'artist'` (Lidarr), or
  /// `'author'` (Readarr).
  final String resourcePath;

  /// `'tvdbId'`, `'tmdbId'`, `'foreignArtistId'`, or `'foreignAuthorId'`.
  final String idFieldName;

  /// `'v3'` for Sonarr/Radarr, `'v1'` for Lidarr/Readarr.
  final String apiVersion;

  final http.Client _client;

  Map<String, String> get _headers => {
    'X-Api-Key': config.apiKey,
    'Content-Type': 'application/json',
  };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final uri = Uri.parse('${config.baseUrl}/api/$apiVersion$path');
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
    final decoded = decodeServerJson(response.body) as List<dynamic>;
    return decoded
        .map(
          (e) => ArrLookupResult.fromJson(
            e as Map<String, dynamic>,
            idFieldName: idFieldName,
          ),
        )
        .toList();
  }

  /// Everything already in the library. The media hub indexes this once
  /// and reuses it for every title, instead of a per-title lookup call.
  Future<List<ArrLibraryItem>> getLibrary() async {
    final response = await _client
        .get(_uri('/$resourcePath'), headers: _headers)
        .timeout(const Duration(seconds: 30));
    _checkOk(response);
    final decoded = decodeServerJson(response.body) as List<dynamic>;
    return decoded
        .map((e) => ArrLibraryItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ArrQualityProfile>> getQualityProfiles() async {
    final response = await _client
        .get(_uri('/qualityprofile'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final decoded = decodeServerJson(response.body) as List<dynamic>;
    return decoded
        .map((e) => ArrQualityProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ArrRootFolder>> getRootFolders() async {
    final response = await _client
        .get(_uri('/rootfolder'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final decoded = decodeServerJson(response.body) as List<dynamic>;
    return decoded
        .map((e) => ArrRootFolder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Lidarr/Readarr additionally require a metadata profile on add —
  /// Sonarr/Radarr don't have this concept, so callers for those two
  /// simply never call this.
  Future<List<ArrMetadataProfile>> getMetadataProfiles() async {
    final response = await _client
        .get(_uri('/metadataprofile'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final decoded = decodeServerJson(response.body) as List<dynamic>;
    return decoded
        .map((e) => ArrMetadataProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Adds [result] to the library: takes the full looked-up object and
  /// merges in the fields the add endpoint needs, matching what every
  /// *arr client does (they all want the whole metadata object back, not
  /// just a handful of ids).
  Future<void> add({
    required ArrLookupResult result,
    required int qualityProfileId,
    required String rootFolderPath,
    int? metadataProfileId,
    bool searchOnAdd = true,
  }) async {
    final body = {
      ...result.raw,
      'qualityProfileId': qualityProfileId,
      'rootFolderPath': rootFolderPath,
      'monitored': true,
      'metadataProfileId': ?metadataProfileId,
      'addOptions': switch (resourcePath) {
        'series' => {'searchForMissingEpisodes': searchOnAdd, 'monitor': 'all'},
        'artist' => {'searchForMissingAlbums': searchOnAdd, 'monitor': 'all'},
        'author' => {'searchForMissingBooks': searchOnAdd, 'monitor': 'all'},
        _ => {'searchForMovie': searchOnAdd},
      },
    };

    final response = await _client
        .post(_uri('/$resourcePath'), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw MediaApiException('Add failed (${response.statusCode}).');
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
    final body = decodeServerJson(response.body);
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
    final decoded = decodeServerJson(response.body) as List<dynamic>;
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
