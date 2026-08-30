import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ha_api_exception.dart';
import 'models/ha_entity.dart';

/// Thin wrapper over Home Assistant's REST API (`/api/*`).
///
/// See https://developers.home-assistant.io/docs/api/rest/
class HaRestClient {
  HaRestClient({
    required this.baseUrl,
    required this.token,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client();

  /// e.g. `http://homeassistant.local:8123` (no trailing slash).
  final String baseUrl;
  final String token;
  final http.Client _client;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// Validates the server URL + token by hitting `/api/`.
  /// Returns true if Home Assistant responds with its "API running." message.
  Future<bool> checkConnection() async {
    final response = await _client
        .get(_uri('/api/'), headers: _headers)
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 401) {
      throw HaApiException('Invalid access token.');
    }
    if (response.statusCode != 200) {
      throw HaApiException(
        'Unexpected response (${response.statusCode}) from server.',
      );
    }
    return true;
  }

  Future<List<HaEntity>> getStates() async {
    final response = await _client
        .get(_uri('/api/states'), headers: _headers)
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw HaApiException(
        'Failed to fetch states (${response.statusCode}).',
      );
    }

    final decoded = jsonDecode(response.body) as List<dynamic>;
    return decoded
        .map((e) => HaEntity.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> callService(
    String domain,
    String service, {
    String? entityId,
    Map<String, dynamic>? serviceData,
  }) async {
    final body = <String, dynamic>{
      ...?serviceData,
      'entity_id': ?entityId,
    };

    final response = await _client
        .post(
          _uri('/api/services/$domain/$service'),
          headers: _headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw HaApiException(
        'Service call $domain.$service failed (${response.statusCode}).',
      );
    }
  }

  void dispose() => _client.close();
}
