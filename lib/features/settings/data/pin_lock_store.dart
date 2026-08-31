import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists an optional PIN gating access to Settings, mirroring
/// [CredentialsStore]'s storage pattern. `null` means no PIN is set.
class PinLockStore {
  PinLockStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _pinKey = 'settings_pin';

  final FlutterSecureStorage _storage;

  Future<String?> read() => _storage.read(key: _pinKey);

  Future<void> save(String pin) => _storage.write(key: _pinKey, value: pin);

  Future<void> clear() => _storage.delete(key: _pinKey);
}
