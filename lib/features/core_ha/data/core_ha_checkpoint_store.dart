import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/configuration_writes.dart';
import '../../server/domain/server_models.dart';
import '../domain/core_ha_activity_models.dart';

abstract interface class CoreHaCheckpointBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

final class SecureCoreHaCheckpointBackend implements CoreHaCheckpointBackend {
  SecureCoreHaCheckpointBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

final class CoreHaCheckpointException implements Exception {
  const CoreHaCheckpointException(this.code);
  final String code;

  @override
  String toString() => 'CoreHaCheckpointException($code)';
}

Never _fail(String code) => throw CoreHaCheckpointException(code);

/// A device-local trust anchor. It contains no Core credential or HA payload.
/// The signed checkpoint is deliberately exportable for an independent copy.
final class CoreHaTrustedCheckpoint {
  const CoreHaTrustedCheckpoint._({
    required this.context,
    required this.chainId,
    required this.sequence,
    required this.headHash,
    required this.checkpoint,
    required this.pinnedAt,
    required this.revision,
  });

  final ServerContext context;
  final String chainId, headHash, checkpoint;
  final int sequence, revision;
  final DateTime pinnedAt;

  Map<String, Object> toJson() => {
    'version': 1,
    'scope': context.toJson(),
    'chainId': chainId,
    'sequence': sequence,
    'headHash': headHash,
    'checkpoint': checkpoint,
    'pinnedAt': pinnedAt.toUtc().toIso8601String(),
    'revision': revision,
  };

  /// A bounded, versioned plaintext artifact suitable for an offline vault.
  String get exportValue => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is CoreHaTrustedCheckpoint &&
      other.context == context &&
      other.chainId == chainId &&
      other.sequence == sequence &&
      other.headHash == headHash &&
      other.checkpoint == checkpoint &&
      other.pinnedAt == pinnedAt &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(
    context,
    chainId,
    sequence,
    headHash,
    checkpoint,
    pinnedAt,
    revision,
  );
}

/// One encrypted secure-storage record per Core/home pair. Mutations use an
/// exact read-set comparison, so another view or process cannot be overwritten.
final class CoreHaCheckpointStore {
  CoreHaCheckpointStore({
    CoreHaCheckpointBackend? backend,
    DateTime Function()? clock,
  }) : _backend = backend ?? SecureCoreHaCheckpointBackend(),
       _clock = clock ?? DateTime.now;

  static const _prefix = 'core_ha_history_checkpoint_v1';
  static const _maximumRawBytes = 4096;
  final CoreHaCheckpointBackend _backend;
  final DateTime Function() _clock;

  static String storageKey(ServerContext context) =>
      '${_prefix}_${context.coreId}_${context.homeId}';

  void Function() _guard(bool Function() current) {
    var retired = false;
    return () {
      try {
        if (!retired && current()) return;
      } catch (_) {
        // A failed lifecycle/owner callback grants no access.
      }
      retired = true;
      _fail('retired');
    };
  }

  Future<String?> _read(String key, void Function() check) async {
    check();
    try {
      final value = await _backend.read(key);
      check();
      return value;
    } on CoreHaCheckpointException {
      rethrow;
    } catch (_) {
      check();
      _fail('read_failed');
    }
  }

  static CoreHaTrustedCheckpoint? _decode(String? raw, ServerContext expected) {
    if (raw == null) return null;
    try {
      if (raw.length > _maximumRawBytes ||
          utf8.encode(raw).length > _maximumRawBytes) {
        _fail('invalid_record');
      }
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 8 ||
          value.keys.toSet().difference({
            'version',
            'scope',
            'chainId',
            'sequence',
            'headHash',
            'checkpoint',
            'pinnedAt',
            'revision',
          }).isNotEmpty ||
          value['version'] != 1) {
        _fail('invalid_record');
      }
      final context = ServerContext.fromJson(value['scope']);
      final chain = value['chainId'];
      final sequence = value['sequence'];
      final head = value['headHash'];
      final checkpoint = value['checkpoint'];
      final rawPinnedAt = value['pinnedAt'];
      final revision = value['revision'];
      if (context != expected ||
          chain is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(chain) ||
          sequence is! int ||
          sequence < 0 ||
          sequence > 2048 ||
          head is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(head) ||
          checkpoint is! String ||
          checkpoint.isEmpty ||
          checkpoint.length > 512 ||
          checkpoint.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e) ||
          rawPinnedAt is! String ||
          revision is! int ||
          revision < 1 ||
          revision > 0x1fffffffffffff) {
        _fail('invalid_record');
      }
      final pinnedAt = DateTime.parse(rawPinnedAt).toUtc();
      if (pinnedAt.toIso8601String() != rawPinnedAt) {
        _fail('invalid_record');
      }
      return CoreHaTrustedCheckpoint._(
        context: context,
        chainId: chain,
        sequence: sequence,
        headHash: head,
        checkpoint: checkpoint,
        pinnedAt: pinnedAt,
        revision: revision,
      );
    } on CoreHaCheckpointException {
      rethrow;
    } catch (_) {
      _fail('invalid_record');
    }
  }

  static CoreHaTrustedCheckpoint _record(
    ServerContext context,
    CoreHaHistoryVerification proof,
    DateTime pinnedAt,
    int revision,
  ) => CoreHaTrustedCheckpoint._(
    context: context,
    chainId: proof.chainId,
    sequence: proof.sequence,
    headHash: proof.headHash,
    checkpoint: proof.checkpoint,
    pinnedAt: pinnedAt.toUtc(),
    revision: revision,
  );

  Future<CoreHaTrustedCheckpoint?> read(
    ServerContext context, {
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent), key = storageKey(context);
    return ConfigurationWrites.run(() async {
      final raw = await _read(key, check);
      final record = _decode(raw, context);
      check();
      return record;
    });
  }

  Future<CoreHaTrustedCheckpoint> pin(
    ServerContext context,
    CoreHaHistoryVerification proof, {
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent), key = storageKey(context);
    return ConfigurationWrites.run(() async {
      if (proof.comparedCheckpoint) _fail('untrusted_proof');
      final before = await _read(key, check);
      if (_decode(before, context) != null) _fail('already_pinned');
      final record = _record(context, proof, _clock(), 1);
      final encoded = jsonEncode(record.toJson());
      check();
      try {
        await _backend.write(key, encoded);
      } catch (_) {
        check();
        _fail('write_failed');
      }
      check();
      return record;
    });
  }

  Future<CoreHaTrustedCheckpoint> rotate(
    ServerContext context,
    CoreHaTrustedCheckpoint before,
    CoreHaHistoryVerification proof, {
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent), key = storageKey(context);
    return ConfigurationWrites.run(() async {
      if (before.context != context ||
          !proof.comparedCheckpoint ||
          proof.chainId != before.chainId) {
        _fail('untrusted_proof');
      }
      if (proof.sequence < before.sequence ||
          proof.sequence == before.sequence &&
              (proof.headHash != before.headHash ||
                  proof.checkpoint != before.checkpoint)) {
        _fail('rollback');
      }
      if (proof.checkpoint == before.checkpoint) _fail('unchanged');
      final raw = await _read(key, check);
      final current = _decode(raw, context);
      if (current != before) _fail('conflict');
      if (before.revision >= 0x1fffffffffffff) _fail('limit');
      final record = _record(context, proof, _clock(), before.revision + 1);
      check();
      try {
        await _backend.write(key, jsonEncode(record.toJson()));
      } catch (_) {
        check();
        _fail('write_failed');
      }
      check();
      return record;
    });
  }
}
