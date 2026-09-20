import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/configuration_writes.dart';
import '../../server/domain/server_models.dart';

abstract interface class CoreHaEventCheckpointBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

final class SecureCoreHaEventCheckpointBackend
    implements CoreHaEventCheckpointBackend {
  SecureCoreHaEventCheckpointBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

final class CoreHaEventCheckpointException implements Exception {
  const CoreHaEventCheckpointException(this.code);
  final String code;

  @override
  String toString() => 'CoreHaEventCheckpointException($code)';
}

Never _fail(String code) => throw CoreHaEventCheckpointException(code);

final class CoreHaEventCheckpointScope {
  CoreHaEventCheckpointScope({
    required this.context,
    required this.resourceId,
    required this.actorId,
    required this.role,
  }) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(resourceId) ||
        actorId.isEmpty ||
        actorId.length > 128 ||
        actorId.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      _fail('invalid_scope');
    }
  }

  final ServerContext context;
  final String resourceId, actorId;
  final ServerRole role;

  Map<String, Object> toJson() => {
    'context': context.toJson(),
    'resourceId': resourceId,
    'actorId': actorId,
    'role': role.name,
  };

  @override
  bool operator ==(Object other) =>
      other is CoreHaEventCheckpointScope &&
      other.context == context &&
      other.resourceId == resourceId &&
      other.actorId == actorId &&
      other.role == role;

  @override
  int get hashCode => Object.hash(context, resourceId, actorId, role);
}

final class CoreHaEventCheckpoint {
  const CoreHaEventCheckpoint._({
    required this.scope,
    required this.chainId,
    required this.headSequence,
    required this.verifiedAt,
    required this.revision,
  });

  final CoreHaEventCheckpointScope scope;
  final String chainId;
  final int headSequence, revision;
  final DateTime verifiedAt;

  Map<String, Object> toJson() => {
    'version': 1,
    ...scope.toJson(),
    'chainId': chainId,
    'headSequence': headSequence,
    'verifiedAt': verifiedAt.toUtc().toIso8601String(),
    'revision': revision,
  };

  @override
  bool operator ==(Object other) =>
      other is CoreHaEventCheckpoint &&
      other.scope == scope &&
      other.chainId == chainId &&
      other.headSequence == headSequence &&
      other.verifiedAt == verifiedAt &&
      other.revision == revision;

  @override
  int get hashCode =>
      Object.hash(scope, chainId, headSequence, verifiedAt, revision);
}

/// Device-local event-chain anchor. It stores no command payload or credential.
/// Reads and advances are serialized with every other configuration mutation.
final class CoreHaEventCheckpointStore {
  CoreHaEventCheckpointStore({
    CoreHaEventCheckpointBackend? backend,
    DateTime Function()? clock,
  }) : _backend = backend ?? SecureCoreHaEventCheckpointBackend(),
       _clock = clock ?? DateTime.now;

  static const _prefix = 'core_ha_event_checkpoint_v1';
  static const _maximumRawBytes = 4096;
  final CoreHaEventCheckpointBackend _backend;
  final DateTime Function() _clock;

  static String storageKey(CoreHaEventCheckpointScope scope) {
    final identity = jsonEncode([
      scope.context.coreId,
      scope.context.homeId,
      scope.resourceId,
      scope.actorId,
      scope.role.name,
    ]);
    return '${_prefix}_${sha256.convert(utf8.encode(identity))}';
  }

  void Function() _guard(bool Function() current) {
    var retired = false;
    return () {
      try {
        if (!retired && current()) return;
      } catch (_) {
        // A failed lifecycle or authority callback grants no access.
      }
      retired = true;
      _fail('retired');
    };
  }

  Future<String?> _read(String key, void Function() check) async {
    check();
    try {
      final raw = await _backend.read(key);
      check();
      return raw;
    } on CoreHaEventCheckpointException {
      rethrow;
    } catch (_) {
      check();
      _fail('read_failed');
    }
  }

  static CoreHaEventCheckpoint? _decode(
    String? raw,
    CoreHaEventCheckpointScope expected,
  ) {
    if (raw == null) return null;
    try {
      if (raw.length > _maximumRawBytes ||
          utf8.encode(raw).length > _maximumRawBytes) {
        _fail('invalid_record');
      }
      final value = jsonDecode(raw);
      const fields = {
        'version',
        'context',
        'resourceId',
        'actorId',
        'role',
        'chainId',
        'headSequence',
        'verifiedAt',
        'revision',
      };
      if (value is! Map ||
          value.length != fields.length ||
          value.keys.any((key) => !fields.contains(key)) ||
          value['version'] != 1) {
        _fail('invalid_record');
      }
      final role = switch (value['role']) {
        'admin' => ServerRole.admin,
        'member' => ServerRole.member,
        _ => _fail('invalid_record'),
      };
      final resourceId = value['resourceId'];
      final actorId = value['actorId'];
      if (resourceId is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(resourceId) ||
          actorId is! String ||
          actorId.isEmpty ||
          actorId.length > 128 ||
          actorId.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
        _fail('invalid_record');
      }
      final scope = CoreHaEventCheckpointScope(
        context: ServerContext.fromJson(value['context']),
        resourceId: resourceId,
        actorId: actorId,
        role: role,
      );
      final chain = value['chainId'];
      final head = value['headSequence'];
      final rawVerifiedAt = value['verifiedAt'];
      final revision = value['revision'];
      if (scope != expected ||
          chain is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(chain) ||
          head is! int ||
          head < 0 ||
          head > 2048 ||
          rawVerifiedAt is! String ||
          revision is! int ||
          revision < 1 ||
          revision > 0x1fffffffffffff) {
        _fail('invalid_record');
      }
      final verifiedAt = DateTime.parse(rawVerifiedAt).toUtc();
      if (verifiedAt.toIso8601String() != rawVerifiedAt) {
        _fail('invalid_record');
      }
      return CoreHaEventCheckpoint._(
        scope: scope,
        chainId: chain,
        headSequence: head,
        verifiedAt: verifiedAt,
        revision: revision,
      );
    } on CoreHaEventCheckpointException {
      rethrow;
    } catch (_) {
      _fail('invalid_record');
    }
  }

  Future<CoreHaEventCheckpoint?> read(
    CoreHaEventCheckpointScope scope, {
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent), key = storageKey(scope);
    return ConfigurationWrites.run(() async {
      final result = _decode(await _read(key, check), scope);
      check();
      return result;
    });
  }

  Future<CoreHaEventCheckpoint> advance(
    CoreHaEventCheckpointScope scope, {
    required CoreHaEventCheckpoint? before,
    required String chainId,
    required int headSequence,
    bool allowChainReplacement = false,
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent), key = storageKey(scope);
    return ConfigurationWrites.run(() async {
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(chainId) ||
          headSequence < 0 ||
          headSequence > 2048 ||
          before != null && before.scope != scope) {
        _fail('invalid_proof');
      }
      final current = _decode(await _read(key, check), scope);
      if (current != before) _fail('conflict');
      if (current != null) {
        if (current.chainId != chainId) {
          if (!allowChainReplacement) _fail('chain_changed');
        } else {
          if (headSequence < current.headSequence) _fail('rollback');
          if (headSequence == current.headSequence) return current;
        }
        if (current.revision >= 0x1fffffffffffff) _fail('limit');
      }
      final next = CoreHaEventCheckpoint._(
        scope: scope,
        chainId: chainId,
        headSequence: headSequence,
        verifiedAt: _clock().toUtc(),
        revision: (current?.revision ?? 0) + 1,
      );
      check();
      try {
        await _backend.write(key, jsonEncode(next.toJson()));
      } catch (_) {
        check();
        _fail('write_failed');
      }
      check();
      return next;
    });
  }
}
