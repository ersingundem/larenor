import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/direct_credential_record.dart';
import '../../../core/direct_home_access.dart';
import 'proxmox_config.dart';

/// Ticket authentication uses a complete, source-owned six-field record.
/// An incomplete record requires an explicit reconnect or clear, never migration.
class ProxmoxCredentialsStore {
  ProxmoxCredentialsStore({
    FlutterSecureStorage? storage,
    DirectHomeAccess? access,
  }) : _access = access,
       _record = DirectCredentialRecord(
         service: DirectCredentialService.proxmox,
         storage: storage,
         access: access,
       );
  final DirectHomeAccess? _access;
  final DirectCredentialRecord _record;

  Future<ProxmoxConfig?> read() async {
    final fields = await _record.readFields();
    _access?.check();
    if (fields.values.every((value) => value == null)) return null;
    final port = int.tryParse(fields['port'] ?? '');
    final tls = fields['allowSelfSigned'];
    if (fields.values.any((value) => value == null || value.isEmpty) ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        '$port' != fields['port'] ||
        !{'true', 'false'}.contains(tls)) {
      throw const DirectHomeAccessException('pending_mutation');
    }
    return ProxmoxConfig(
      host: fields['host']!,
      port: port,
      username: fields['username']!,
      realm: fields['realm']!,
      password: fields['password']!,
      allowSelfSigned: tls == 'true',
    );
  }

  Future<void> save({
    required String host,
    required int port,
    required String username,
    required String realm,
    required String password,
    required bool allowSelfSigned,
    bool Function()? isCurrent,
  }) => _record.replaceAll({
    'host': host,
    'port': '$port',
    'username': username,
    'realm': realm,
    'password': password,
    'allowSelfSigned': '$allowSelfSigned',
  }, isCurrent: isCurrent);

  Future<void> clear({bool Function()? isCurrent}) =>
      _record.clear(isCurrent: isCurrent);
}
