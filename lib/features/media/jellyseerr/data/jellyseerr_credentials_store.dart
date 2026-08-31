import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'jellyseerr_config.dart';

class JellyseerrCredentialsStore {
  JellyseerrCredentialsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _baseUrlKey = 'jellyseerr_base_url';
  static const _apiKeyKey = 'jellyseerr_api_key';

  final FlutterSecureStorage _storage;

  Future<JellyseerrConfig?> read() async {
    final baseUrl = await _storage.read(key: _baseUrlKey);
    final apiKey = await _storage.read(key: _apiKeyKey);
    if (baseUrl == null || apiKey == null) return null;
    return JellyseerrConfig(baseUrl: baseUrl, apiKey: apiKey);
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
