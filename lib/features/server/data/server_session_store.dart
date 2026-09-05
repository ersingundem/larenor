import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/server_models.dart';

abstract interface class ServerSessionPersistence {
  Future<ServerSession?> read();
  Future<void> write(ServerSession? session);
}

/// One atomic v2 record binds credentials, pending-auth intent and Core context.
/// The existing key also reads legacy v1 records without trusting their scope.
/// Excluded from
/// BackupSnapshot's allowlist; a restored configuration never restores sessions.
class SecureServerSessionStore implements ServerSessionPersistence {
  SecureServerSessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'larenor_server_session_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<ServerSession?> read() async {
    try {
      final value = await _storage.read(key: key);
      return value == null ? null : ServerSession.decodeStorage(value);
    } on LarenorServerException {
      rethrow;
    } catch (_) {
      throw const LarenorServerException('storage_failed');
    }
  }

  @override
  Future<void> write(ServerSession? session) async {
    try {
      if (session == null) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: session.encodeStorage());
      }
    } catch (_) {
      throw const LarenorServerException('storage_failed');
    }
  }
}
