import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/family_board_models.dart';
import 'family_board_controller.dart';

abstract interface class FamilyBoardCacheBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class SecureFamilyBoardCacheBackend implements FamilyBoardCacheBackend {
  SecureFamilyBoardCacheBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

final class SecureFamilyBoardCache implements FamilyBoardCache {
  SecureFamilyBoardCache({FamilyBoardCacheBackend? backend})
    : _backend = backend ?? SecureFamilyBoardCacheBackend();
  static const maximumBytes = 1024 * 1024;
  final FamilyBoardCacheBackend _backend;

  String _key(FamilyBoardBinding binding) {
    final identity = jsonEncode([
      'family-board-cache-v1',
      binding.coreId,
      binding.homeId,
      binding.homeRevision,
      binding.boardId,
      binding.accountId,
      binding.accountRevision,
      binding.memberRevision,
      binding.sessionFamilyId,
    ]);
    return 'family_board_v1_${sha256.convert(utf8.encode(identity))}';
  }

  String _pendingKey(FamilyBoardBinding binding) {
    final identity = jsonEncode([
      'family-board-pending-v1',
      binding.coreId,
      binding.homeId,
      binding.boardId,
      binding.accountId,
    ]);
    return 'family_board_pending_v1_${sha256.convert(utf8.encode(identity))}';
  }

  FamilyBoardCommand _pendingEnvelope(
    Object? raw,
    FamilyBoardBinding authority,
  ) {
    if (raw is! Map ||
        raw.length != 3 ||
        raw['schemaVersion'] != 1 ||
        !raw.containsKey('authority') ||
        !raw.containsKey('command')) {
      throw const FamilyBoardException('invalid_cache');
    }
    final storedAuthority = raw['authority'];
    final expectedAuthority = authority.serverAuthority;
    if (storedAuthority is! Map ||
        storedAuthority.length != expectedAuthority.length ||
        !expectedAuthority.entries.every(
          (entry) => storedAuthority[entry.key] == entry.value,
        )) {
      throw const FamilyBoardException('invalid_cache');
    }
    return FamilyBoardCommand.fromJson(raw['command']);
  }

  void _current(FamilyBoardBinding binding, bool Function() check) {
    try {
      if (binding.active && check()) return;
    } catch (_) {
      /* fail closed */
    }
    throw const FamilyBoardException('cancelled');
  }

  @override
  Future<FamilyBoardSnapshot?> read(
    FamilyBoardBinding authority, {
    required bool Function() isCurrent,
  }) async {
    final key = _key(authority);
    _current(authority, isCurrent);
    try {
      final raw = await _backend.read(key);
      _current(authority, isCurrent);
      if (raw == null) return null;
      if (utf8.encode(raw).length > maximumBytes) {
        throw const FamilyBoardException('invalid_cache');
      }
      final decoded = jsonDecode(raw);
      final value = FamilyBoardSnapshot.fromJson(decoded, authority);
      _current(authority, isCurrent);
      return value;
    } on FamilyBoardException catch (error) {
      if (error.code == 'cancelled') rethrow;
      await _backend.delete(key);
      _current(authority, isCurrent);
      return null;
    } catch (_) {
      _current(authority, isCurrent);
      await _backend.delete(key);
      _current(authority, isCurrent);
      return null;
    }
  }

  @override
  Future<void> write(
    FamilyBoardSnapshot snapshot, {
    required bool Function() isCurrent,
  }) async {
    final authority = snapshot.binding;
    _current(authority, isCurrent);
    final raw = encodeBoardSnapshot(snapshot);
    if (utf8.encode(raw).length > maximumBytes) {
      throw const FamilyBoardException('invalid_cache');
    }
    final key = _key(authority);
    await _backend.write(key, raw);
    try {
      _current(authority, isCurrent);
    } on FamilyBoardException {
      await _backend.delete(key);
      rethrow;
    }
  }

  @override
  Future<FamilyBoardCommand?> readPending(
    FamilyBoardBinding authority, {
    required bool Function() isCurrent,
  }) async {
    final key = _pendingKey(authority);
    _current(authority, isCurrent);
    try {
      final raw = await _backend.read(key);
      _current(authority, isCurrent);
      if (raw == null) return null;
      if (utf8.encode(raw).length > maximumBytes) {
        throw const FamilyBoardException('invalid_cache');
      }
      return _pendingEnvelope(jsonDecode(raw), authority);
    } on FamilyBoardException catch (error) {
      if (error.code == 'cancelled') rethrow;
      throw const FamilyBoardException('invalid_cache');
    } catch (_) {
      _current(authority, isCurrent);
      throw const FamilyBoardException('invalid_cache');
    }
  }

  @override
  Future<void> writePending(
    FamilyBoardBinding authority,
    FamilyBoardCommand command, {
    required bool Function() isCurrent,
  }) async {
    _current(authority, isCurrent);
    final raw = jsonEncode({
      'schemaVersion': 1,
      'authority': authority.serverAuthority,
      'command': command.toJson(),
    });
    if (utf8.encode(raw).length > maximumBytes) {
      throw const FamilyBoardException('invalid_cache');
    }
    final key = _pendingKey(authority);
    await _backend.write(key, raw);
    try {
      _current(authority, isCurrent);
    } on FamilyBoardException {
      await _backend.delete(key);
      rethrow;
    }
  }

  @override
  Future<void> clearPending(
    FamilyBoardBinding authority,
    String requestId, {
    required bool Function() isCurrent,
  }) async {
    _current(authority, isCurrent);
    final key = _pendingKey(authority);
    final raw = await _backend.read(key);
    _current(authority, isCurrent);
    if (raw == null ||
        _pendingEnvelope(jsonDecode(raw), authority).requestId != requestId) {
      throw const FamilyBoardException('invalid_cache');
    }
    await _backend.delete(key);
    _current(authority, isCurrent);
  }
}
