import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/direct_credential_record.dart';
import '../../../core/direct_home_access.dart';
import 'keenetic_config.dart';

/// The local Web UI session uses one complete URL/user/password tuple.
/// Cookies are transient. Uncertain writes require explicit save or clear.
class KeeneticCredentialsStore {
  KeeneticCredentialsStore({
    FlutterSecureStorage? storage,
    DirectHomeAccess? access,
  }) : _access = access,
       _record = DirectCredentialRecord(
         service: DirectCredentialService.keenetic,
         storage: storage,
         access: access,
       );

  final DirectHomeAccess? _access;
  final DirectCredentialRecord _record;

  static KeeneticConfig _validated(
    String baseUrl,
    String username,
    String password,
  ) {
    try {
      if (baseUrl.length > 2048 ||
          username.trim().isEmpty ||
          username.length > 4096 ||
          password.length > 4096 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(username)) {
        throw const FormatException();
      }
      return KeeneticConfig(
        baseUrl: KeeneticConfig.normalizeBaseUrl(baseUrl),
        username: username,
        password: password,
      );
    } catch (_) {
      throw const DirectHomeAccessException('invalid_record');
    }
  }

  Future<KeeneticConfig?> read() async {
    final fields = await _record.readFields();
    _access?.check();
    if (fields.values.every((value) => value == null)) return null;
    final baseUrl = fields['baseUrl'],
        username = fields['username'],
        password = fields['password'];
    if (baseUrl == null || username == null || password == null) {
      throw const DirectHomeAccessException('invalid_record');
    }
    return _validated(baseUrl, username, password);
  }

  Future<void> save({
    required String baseUrl,
    required String username,
    required String password,
    bool Function()? isCurrent,
  }) {
    _access?.check();
    final value = _validated(baseUrl, username, password);
    return _record.replaceAll({
      'baseUrl': value.baseUrl,
      'username': value.username,
      'password': value.password,
    }, isCurrent: isCurrent);
  }

  Future<void> clear({bool Function()? isCurrent}) =>
      _record.clear(isCurrent: isCurrent);
}
