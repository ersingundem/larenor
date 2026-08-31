import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'arr_config.dart';

/// Shared credentials store for Sonarr and Radarr — same auth shape
/// (URL + API key) for both, keyed by a [servicePrefix] so one class
/// covers both instead of two near-duplicate stores.
class ArrCredentialsStore {
  ArrCredentialsStore({
    required this.servicePrefix,
    FlutterSecureStorage? storage,
  }) : _storage = storage ?? const FlutterSecureStorage();

  final String servicePrefix;
  final FlutterSecureStorage _storage;

  String get _baseUrlKey => '${servicePrefix}_base_url';
  String get _apiKeyKey => '${servicePrefix}_api_key';

  Future<ArrConfig?> read() async {
    final baseUrl = await _storage.read(key: _baseUrlKey);
    final apiKey = await _storage.read(key: _apiKeyKey);
    if (baseUrl == null || apiKey == null) return null;
    return ArrConfig(baseUrl: baseUrl, apiKey: apiKey);
  }

  Future<void> save({required String baseUrl, required String apiKey}) async {
    await _storage.write(key: _baseUrlKey, value: baseUrl);
    await _storage.write(key: _apiKeyKey, value: apiKey);
  }

  Future<void> clear() async {
    await _storage.delete(key: _baseUrlKey);
    await _storage.delete(key: _apiKeyKey);
  }
}
