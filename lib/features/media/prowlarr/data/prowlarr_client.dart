import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../data/media_api_exception.dart';
import 'prowlarr_config.dart';
import 'models/prowlarr_indexer.dart';

/// Thin hand-rolled client over Prowlarr's REST API — same Servarr-family
/// conventions as Sonarr/Radarr (`X-Api-Key`, camelCase JSON), verified
/// against Prowlarr's own `IndexerController`/`IndexerDefinition` source.
/// Scope is list + enable/disable only — adding a new indexer needs a
/// provider-specific field schema, out of scope here.
class ProwlarrClient {
  ProwlarrClient({required this.config, http.Client? httpClient})
    : _client = httpClient ?? http.Client();

  final ProwlarrConfig config;
  final http.Client _client;

  Map<String, String> get _headers => {
    'X-Api-Key': config.apiKey,
    'Content-Type': 'application/json',
  };

  Uri _uri(String path) => Uri.parse('${config.baseUrl}/api/v1$path');

  Future<void> checkConnection() async {
    final response = await _client
        .get(_uri('/system/status'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw MediaApiException('Invalid server URL or API key.');
    }
  }

  Future<List<ProwlarrIndexer>> getIndexers() async {
    final response = await _client
        .get(_uri('/indexer'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
    final decoded = jsonDecode(response.body) as List<dynamic>;
    return decoded
        .map((e) => ProwlarrIndexer.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> setIndexerEnabled(ProwlarrIndexer indexer, bool enabled) async {
    final body = {...indexer.raw, 'enable': enabled};
    final response = await _client
        .put(
          _uri('/indexer/${indexer.id}'),
          headers: _headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    _checkOk(response);
  }

  void _checkOk(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MediaApiException('Request failed (${response.statusCode}).');
    }
  }

  void dispose() => _client.close();
}
