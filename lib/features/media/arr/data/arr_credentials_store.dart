import 'package:larenor/core/direct_credential_record.dart';
import 'package:larenor/core/direct_home_access.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'arr_config.dart';

/// Shared URL/API-key record for Sonarr, Radarr, Lidarr and Readarr.
/// Only these four closed [servicePrefix] values select local storage keys.
class ArrCredentialsStore {
  ArrCredentialsStore({
    required this.servicePrefix,
    FlutterSecureStorage? storage,
    DirectHomeAccess? access,
  }) : _access = access,
       _record = DirectCredentialRecord(
         service: _service(servicePrefix),
         storage: storage,
         access: access,
       );

  final String servicePrefix;
  final DirectCredentialRecord _record;
  final DirectHomeAccess? _access;
  static DirectCredentialService _service(String prefix) => switch (prefix) {
    'sonarr' => DirectCredentialService.sonarr,
    'radarr' => DirectCredentialService.radarr,
    'lidarr' => DirectCredentialService.lidarr,
    'readarr' => DirectCredentialService.readarr,
    _ => throw ArgumentError('unsupported_service'),
  };

  Future<ArrConfig?> read() async {
    final fields = await _record.readFields();
    _access?.check();
    final baseUrl = fields['baseUrl'];
    final apiKey = fields['apiKey'];
    if (baseUrl == null || apiKey == null) return null;
    return ArrConfig(baseUrl: baseUrl, apiKey: apiKey);
  }

  Future<void> save({
    required String baseUrl,
    required String apiKey,
    bool Function()? isCurrent,
  }) => _record.replaceAll({
    'baseUrl': baseUrl,
    'apiKey': apiKey,
  }, isCurrent: isCurrent);

  Future<void> clear({bool Function()? isCurrent}) =>
      _record.clear(isCurrent: isCurrent);
}
