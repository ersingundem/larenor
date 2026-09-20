import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/configuration_writes.dart';
import '../../server/domain/server_models.dart';

abstract interface class CoreBoundedEventCheckpointBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

final class SecureCoreBoundedEventCheckpointBackend
    implements CoreBoundedEventCheckpointBackend {
  SecureCoreBoundedEventCheckpointBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

final class CoreBoundedEventCheckpointException implements Exception {
  const CoreBoundedEventCheckpointException(this.code);
  final String code;

  @override
  String toString() => 'CoreBoundedEventCheckpointException($code)';
}

Never _fail(String code) => throw CoreBoundedEventCheckpointException(code);

final class CoreBoundedEventCheckpointScope {
  CoreBoundedEventCheckpointScope({
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
      other is CoreBoundedEventCheckpointScope &&
      other.context == context &&
      other.resourceId == resourceId &&
      other.actorId == actorId &&
      other.role == role;

  @override
  int get hashCode => Object.hash(context, resourceId, actorId, role);
}

final class CoreBoundedEventCheckpoint {
  const CoreBoundedEventCheckpoint._({
    required this.scope,
    required this.chainId,
    required this.headSequence,
    required this.headCheckpoint,
    required this.verifiedAt,
    required this.revision,
  });

  final CoreBoundedEventCheckpointScope scope;
  final String chainId;

  /// Null only while migrating a valid v1 anchor, whose schema predates the
  /// authenticated head proof. Such an anchor still enforces chain and
  /// sequence monotonicity and is never exposed as a trusted v2 record.
  final String? headCheckpoint;
  final int headSequence, revision;
  final DateTime verifiedAt;

  Map<String, Object> toJson() {
    final proof = headCheckpoint;
    if (proof == null) _fail('invalid_record');
    return {
      'version': 2,
      ...scope.toJson(),
      'chainId': chainId,
      'headSequence': headSequence,
      'headCheckpoint': proof,
      'verifiedAt': verifiedAt.toUtc().toIso8601String(),
      'revision': revision,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is CoreBoundedEventCheckpoint &&
      other.scope == scope &&
      other.chainId == chainId &&
      other.headSequence == headSequence &&
      other.headCheckpoint == headCheckpoint &&
      other.verifiedAt == verifiedAt &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(
    scope,
    chainId,
    headSequence,
    headCheckpoint,
    verifiedAt,
    revision,
  );
}

/// Device-local bounded-transfer event-chain anchor.
///
/// It stores no payload or credential. Reads and advances are serialized with
/// every other configuration mutation.
final class CoreBoundedEventCheckpointStore {
  CoreBoundedEventCheckpointStore({
    CoreBoundedEventCheckpointBackend? backend,
    DateTime Function()? clock,
  }) : _backend = backend ?? SecureCoreBoundedEventCheckpointBackend(),
       _clock = clock ?? DateTime.now;

  static const _prefix = 'core_bounded_event_checkpoint_v2';
  static const _legacyPrefix = 'core_bounded_event_checkpoint_v1';
  static const _maximumRawBytes = 4096;
  final CoreBoundedEventCheckpointBackend _backend;
  final DateTime Function() _clock;

  static String _storageKey(
    CoreBoundedEventCheckpointScope scope,
    String prefix,
  ) {
    final identity = jsonEncode([
      scope.context.coreId,
      scope.context.homeId,
      scope.resourceId,
      scope.actorId,
      scope.role.name,
    ]);
    return '${prefix}_${sha256.convert(utf8.encode(identity))}';
  }

  static String storageKey(CoreBoundedEventCheckpointScope scope) =>
      _storageKey(scope, _prefix);

  static String _legacyStorageKey(CoreBoundedEventCheckpointScope scope) =>
      _storageKey(scope, _legacyPrefix);

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
    } on CoreBoundedEventCheckpointException {
      rethrow;
    } catch (_) {
      check();
      _fail('read_failed');
    }
  }

  static CoreBoundedEventCheckpoint? _decode(
    String? raw,
    CoreBoundedEventCheckpointScope expected, {
    required bool legacy,
  }) {
    if (raw == null) return null;
    try {
      if (raw.length > _maximumRawBytes ||
          utf8.encode(raw).length > _maximumRawBytes) {
        _fail('invalid_record');
      }
      final value = jsonDecode(raw);
      final fields = <String>{
        'version',
        'context',
        'resourceId',
        'actorId',
        'role',
        'chainId',
        'headSequence',
        'verifiedAt',
        'revision',
        if (!legacy) 'headCheckpoint',
      };
      if (value is! Map ||
          value.length != fields.length ||
          value.keys.any((key) => !fields.contains(key)) ||
          value['version'] != (legacy ? 1 : 2)) {
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
      final scope = CoreBoundedEventCheckpointScope(
        context: ServerContext.fromJson(value['context']),
        resourceId: resourceId,
        actorId: actorId,
        role: role,
      );
      final chain = value['chainId'];
      final head = value['headSequence'];
      final headCheckpoint = legacy ? null : value['headCheckpoint'];
      final rawVerifiedAt = value['verifiedAt'];
      final revision = value['revision'];
      if (scope != expected ||
          chain is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(chain) ||
          head is! int ||
          head < 0 ||
          head > 2048 ||
          !legacy &&
              (headCheckpoint is! String ||
                  !RegExp(r'^[0-9a-f]{64}$').hasMatch(headCheckpoint)) ||
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
      return CoreBoundedEventCheckpoint._(
        scope: scope,
        chainId: chain,
        headSequence: head,
        headCheckpoint: headCheckpoint,
        verifiedAt: verifiedAt,
        revision: revision,
      );
    } on CoreBoundedEventCheckpointException {
      rethrow;
    } catch (_) {
      _fail('invalid_record');
    }
  }

  Future<CoreBoundedEventCheckpoint?> read(
    CoreBoundedEventCheckpointScope scope, {
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent), key = storageKey(scope);
    return ConfigurationWrites.run(() async {
      final raw = await _read(key, check);
      final result = raw == null
          ? _decode(
              await _read(_legacyStorageKey(scope), check),
              scope,
              legacy: true,
            )
          : _decode(raw, scope, legacy: false);
      check();
      return result;
    });
  }

  Future<CoreBoundedEventCheckpoint> advance(
    CoreBoundedEventCheckpointScope scope, {
    required CoreBoundedEventCheckpoint? before,
    required String chainId,
    required int headSequence,
    required String headCheckpoint,
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent), key = storageKey(scope);
    return ConfigurationWrites.run(() async {
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(chainId) ||
          headSequence < 0 ||
          headSequence > 2048 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(headCheckpoint) ||
          before != null && before.scope != scope) {
        _fail('invalid_proof');
      }
      final raw = await _read(key, check);
      final current = raw == null
          ? _decode(
              await _read(_legacyStorageKey(scope), check),
              scope,
              legacy: true,
            )
          : _decode(raw, scope, legacy: false);
      if (current != before) _fail('conflict');
      if (current != null) {
        if (current.chainId != chainId) _fail('chain_changed');
        if (headSequence < current.headSequence) _fail('rollback');
        if (headSequence == current.headSequence &&
            current.headCheckpoint != null) {
          if (headCheckpoint != current.headCheckpoint) _fail('rollback');
          return current;
        }
        if (current.revision >= 0x1fffffffffffff) _fail('limit');
      }
      final next = CoreBoundedEventCheckpoint._(
        scope: scope,
        chainId: chainId,
        headSequence: headSequence,
        headCheckpoint: headCheckpoint,
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
