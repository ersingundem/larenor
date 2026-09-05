import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../../core/direct_credential_record.dart';
import '../../../../core/direct_home_access.dart';
import 'qbittorrent_config.dart';

/// Cookie-session login uses one complete, private URL/user/password record.
/// An uncertain field write stays quarantined until explicit save or clear.
class QbittorrentCredentialsStore {
  QbittorrentCredentialsStore({
    FlutterSecureStorage? storage,
    DirectHomeAccess? access,
  }) : _access = access,
       _record = DirectCredentialRecord(
         service: DirectCredentialService.qbittorrent,
         storage: storage,
         access: access,
       );

  final DirectHomeAccess? _access;
  final DirectCredentialRecord _record;

  Future<QbittorrentConfig?> read() async {
    final fields = await _record.readFields();
    _access?.check();
    final baseUrl = fields['baseUrl'];
    final username = fields['username'];
    final password = fields['password'];
    if (baseUrl == null || username == null || password == null) return null;
    return QbittorrentConfig(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
  }

  Future<void> save({
    required String baseUrl,
    required String username,
    required String password,
    bool Function()? isCurrent,
  }) => _record.replaceAll({
    'baseUrl': baseUrl,
    'username': username,
    'password': password,
  }, isCurrent: isCurrent);

  Future<void> clear({bool Function()? isCurrent}) =>
      _record.clear(isCurrent: isCurrent);
}
