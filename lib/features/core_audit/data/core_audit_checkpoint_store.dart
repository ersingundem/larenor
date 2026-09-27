import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/configuration_writes.dart';
import '../../server/domain/server_models.dart';
import '../domain/core_audit_models.dart';

abstract interface class CoreAuditCheckpointBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

final class SecureCoreAuditCheckpointBackend
    implements CoreAuditCheckpointBackend {
  SecureCoreAuditCheckpointBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

final class CoreAuditCheckpointException implements Exception {
  const CoreAuditCheckpointException(this.code);
  final String code;

  @override
  String toString() => 'CoreAuditCheckpointException($code)';
}

Never _fail(String code) => throw CoreAuditCheckpointException(code);

final class CoreAuditTrustedCheckpoint {
  const CoreAuditTrustedCheckpoint._({
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

  @override
  bool operator ==(Object other) =>
      other is CoreAuditTrustedCheckpoint &&
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

/// One device-local trust anchor per Core/home scope. The prefix is separate
/// from Home Assistant history so the two journals can never replace each
/// other's retained authority.
final class CoreAuditCheckpointStore {
  CoreAuditCheckpointStore({
    CoreAuditCheckpointBackend? backend,
    DateTime Function()? clock,
  }) : _backend = backend ?? SecureCoreAuditCheckpointBackend(),
       _clock = clock ?? DateTime.now;

  static const _prefix = 'core_audit_checkpoint_v1';
  static const _maximumRawBytes = 4096;
  final CoreAuditCheckpointBackend _backend;
  final DateTime Function() _clock;

  static String storageKey(ServerContext context) =>
      '${_prefix}_${context.coreId}_${context.homeId}';

  void Function() _guard(bool Function() current) {
    var retired = false;
    return () {
      try {
        if (!retired && current()) return;
      } catch (_) {
        // A failed owner check grants no secure-storage access.
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
    } on CoreAuditCheckpointException {
      rethrow;
    } catch (_) {
      check();
      _fail('read_failed');
    }
  }

  static CoreAuditTrustedCheckpoint? _decode(
    String? raw,
    ServerContext expected,
  ) {
    if (raw == null) return null;
    try {
      if (raw.length > _maximumRawBytes ||
          utf8.encode(raw).length > _maximumRawBytes) {
        _fail('invalid_record');
      }
      final value = jsonDecode(raw);
      const keys = {
        'version',
        'scope',
        'chainId',
        'sequence',
        'headHash',
        'checkpoint',
        'pinnedAt',
        'revision',
      };
      if (value is! Map ||
          value.length != keys.length ||
          !keys.every(value.containsKey) ||
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
          sequence > CoreAuditVerification.maximumSequence ||
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
      return CoreAuditTrustedCheckpoint._(
        context: context,
        chainId: chain,
        sequence: sequence,
        headHash: head,
        checkpoint: checkpoint,
        pinnedAt: pinnedAt,
        revision: revision,
      );
    } on CoreAuditCheckpointException {
      rethrow;
    } catch (_) {
      _fail('invalid_record');
    }
  }

  static CoreAuditTrustedCheckpoint _record(
    ServerContext context,
    CoreAuditVerification proof,
    DateTime pinnedAt,
    int revision,
  ) => CoreAuditTrustedCheckpoint._(
    context: context,
    chainId: proof.chainId,
    sequence: proof.sequence,
    headHash: proof.headHash,
    checkpoint: proof.checkpoint,
    pinnedAt: pinnedAt.toUtc(),
    revision: revision,
  );

  Future<CoreAuditTrustedCheckpoint?> read(
    ServerContext context, {
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent), key = storageKey(context);
    return ConfigurationWrites.run(() async {
      final record = _decode(await _read(key, check), context);
      check();
      return record;
    });
  }

  Future<CoreAuditTrustedCheckpoint> pin(
    ServerContext context,
    CoreAuditVerification proof, {
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent), key = storageKey(context);
    return ConfigurationWrites.run(() async {
      if (proof.context != context || proof.comparedCheckpoint) {
        _fail('untrusted_proof');
      }
      final before = await _read(key, check);
      if (_decode(before, context) != null) _fail('already_pinned');
      final record = _record(context, proof, _clock(), 1);
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

  Future<CoreAuditTrustedCheckpoint> rotate(
    ServerContext context,
    CoreAuditTrustedCheckpoint before,
    CoreAuditVerification proof, {
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent), key = storageKey(context);
    return ConfigurationWrites.run(() async {
      if (before.context != context ||
          proof.context != context ||
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
      final current = _decode(await _read(key, check), context);
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
