import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/server_home_registry.dart';
import '../domain/server_models.dart';

abstract interface class ServerSessionPersistence {
  Future<ServerSession?> read();
  Future<void> write(ServerSession? session);
}

abstract interface class ServerHomeRegistryPersistence {
  Future<ServerHomeRegistry> readRegistry();
  Future<void> writeRegistry(ServerHomeRegistry registry);
}

/// One atomic v4 registry binds profiles, credentials, pending-auth intent and
/// Core context. The existing key also reads legacy session records without
/// trusting their scope.
/// Excluded from
/// BackupSnapshot's allowlist; a restored configuration never restores sessions.
class SecureServerSessionStore
    implements ServerSessionPersistence, ServerHomeRegistryPersistence {
  SecureServerSessionStore({
    FlutterSecureStorage? storage,
    String Function()? profileId,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _profileId = profileId ?? _randomProfileId;

  static const key = 'larenor_server_session_v1';
  final FlutterSecureStorage _storage;
  final String Function() _profileId;

  static String _randomProfileId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  ServerHomeProfile _profile(ServerSession session) {
    final host = session.endpoint.uri.host.trim();
    return ServerHomeProfile(
      profileId: _profileId(),
      label: host.isEmpty ? 'Core' : host.substring(0, min(host.length, 80)),
      session: session,
    );
  }

  Future<String?> _readRaw() async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      throw const LarenorServerException('storage_failed');
    }
  }

  Future<void> _writeRaw(String? value) async {
    try {
      if (value == null) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: value);
      }
    } catch (_) {
      throw const LarenorServerException('storage_failed');
    }
  }

  Future<ServerHomeRegistry> _decode(
    String? value, {
    bool migrate = true,
  }) async {
    if (value == null) return const ServerHomeRegistry.empty();
    try {
      final registry = ServerHomeRegistry.decode(value);
      return registry;
    } on LarenorServerException {
      final session = ServerSession.decodeStorage(value);
      final profile = _profile(session);
      final registry = ServerHomeRegistry(
        activeProfileId: profile.profileId,
        profiles: [profile],
      );
      if (migrate) await _writeRaw(registry.encode());
      return registry;
    }
  }

  @override
  Future<ServerSession?> read() async {
    final registry = await readRegistry();
    return registry.activeProfile?.session;
  }

  @override
  Future<void> write(ServerSession? session) async {
    final ServerHomeRegistry registry;
    try {
      registry = await _decode(await _readRaw(), migrate: false);
    } on LarenorServerException catch (error) {
      if (session == null && error.code == 'storage_failed') {
        // A sign-out must still attempt the physical key deletion when the
        // current registry cannot be read. No profile can be selected safely
        // from an unreadable record, so retaining the whole credential blob
        // would be the less safe outcome.
        await _writeRaw(null);
        return;
      }
      rethrow;
    }
    final active = registry.activeProfile;
    if (session == null) {
      if (active == null) return;
      final remaining = registry.profiles
          .where((item) => item.profileId != active.profileId)
          .toList(growable: false);
      await _writeRaw(
        remaining.isEmpty
            ? null
            : ServerHomeRegistry(
                activeProfileId: null,
                profiles: remaining,
              ).encode(),
      );
      return;
    }
    final ServerHomeRegistry next;
    if (active == null) {
      if (registry.profiles.length >= maxServerHomeProfiles) {
        throw const LarenorServerException('profile_limit');
      }
      final profile = _profile(session);
      next = ServerHomeRegistry(
        activeProfileId: profile.profileId,
        profiles: [...registry.profiles, profile],
      );
    } else {
      next = ServerHomeRegistry(
        activeProfileId: active.profileId,
        profiles: [
          for (final profile in registry.profiles)
            profile.profileId == active.profileId
                ? profile.withSession(session)
                : profile,
        ],
      );
    }
    await writeRegistry(next);
  }

  @override
  Future<ServerHomeRegistry> readRegistry() async => _decode(await _readRaw());

  @override
  Future<void> writeRegistry(ServerHomeRegistry registry) async {
    // Encoding followed by decoding applies the exact same strict contract to
    // in-memory callers before any credential record is replaced.
    final encoded = registry.encode();
    ServerHomeRegistry.decode(encoded);
    await _writeRaw(registry.profiles.isEmpty ? null : encoded);
  }
}
