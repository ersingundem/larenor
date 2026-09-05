import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../../core/direct_credential_record.dart';
import '../../../../core/direct_home_access.dart';
import 'prowlarr_config.dart';

class ProwlarrCredentialsStore {
  ProwlarrCredentialsStore({
    FlutterSecureStorage? storage,
    DirectHomeAccess? access,
  }) : _access = access,
       _record = DirectCredentialRecord(
         service: DirectCredentialService.prowlarr,
         storage: storage,
         access: access,
       );

  final DirectCredentialRecord _record;
  final DirectHomeAccess? _access;

  Future<ProwlarrConfig?> read() async {
    final fields = await _record.readFields();
    _access?.check();
    final baseUrl = fields['baseUrl'];
    final apiKey = fields['apiKey'];
    if (baseUrl == null || apiKey == null) return null;
    return ProwlarrConfig(baseUrl: baseUrl, apiKey: apiKey);
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
