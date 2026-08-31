import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'prowlarr_config.dart';

class ProwlarrCredentialsStore {
  ProwlarrCredentialsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _baseUrlKey = 'prowlarr_base_url';
  static const _apiKeyKey = 'prowlarr_api_key';

  final FlutterSecureStorage _storage;

  Future<ProwlarrConfig?> read() async {
    final baseUrl = await _storage.read(key: _baseUrlKey);
    final apiKey = await _storage.read(key: _apiKeyKey);
    if (baseUrl == null || apiKey == null) return null;
    return ProwlarrConfig(baseUrl: baseUrl, apiKey: apiKey);
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
