import 'package:larenor/core/configuration_writes.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'proxmox_config.dart';

/// Proxmox's API is ticket/cookie-session based — and container console
/// access specifically requires ticket auth rather than an API token (see
/// `proxmox_client.dart`) — so the username/password are kept
/// (Keystore/Keychain-backed) to re-authenticate every session, the same
/// pattern already used for qBittorrent.
class ProxmoxCredentialsStore {
  ProxmoxCredentialsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _hostKey = 'proxmox_host';
  static const _portKey = 'proxmox_port';
  static const _usernameKey = 'proxmox_username';
  static const _realmKey = 'proxmox_realm';
  static const _passwordKey = 'proxmox_password';
  static const _allowSelfSignedKey = 'proxmox_allow_self_signed';

  final FlutterSecureStorage _storage;

  Future<ProxmoxConfig?> read() async {
    final host = await _storage.read(key: _hostKey);
    final port = await _storage.read(key: _portKey);
    final username = await _storage.read(key: _usernameKey);
    final realm = await _storage.read(key: _realmKey);
    final password = await _storage.read(key: _passwordKey);
    if (host == null ||
        port == null ||
        username == null ||
        realm == null ||
        password == null) {
      return null;
    }
    final allowSelfSigned = await _storage.read(key: _allowSelfSignedKey);
    return ProxmoxConfig(
      host: host,
      port: int.tryParse(port) ?? 8006,
      username: username,
      realm: realm,
      password: password,
      allowSelfSigned: allowSelfSigned != 'false',
    );
  }

  Future<void> save({
    required String host,
    required int port,
    required String username,
    required String realm,
    required String password,
    required bool allowSelfSigned,
  }) => ConfigurationWrites.run(() async {
    await _storage.write(key: _hostKey, value: host);
    await _storage.write(key: _portKey, value: '$port');
    await _storage.write(key: _usernameKey, value: username);
    await _storage.write(key: _realmKey, value: realm);
    await _storage.write(key: _passwordKey, value: password);
    await _storage.write(key: _allowSelfSignedKey, value: '$allowSelfSigned');
  });

  Future<void> clear() => ConfigurationWrites.run(() async {
    await _storage.delete(key: _hostKey);
    await _storage.delete(key: _portKey);
    await _storage.delete(key: _usernameKey);
    await _storage.delete(key: _realmKey);
    await _storage.delete(key: _passwordKey);
    await _storage.delete(key: _allowSelfSignedKey);
  });
}
