import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/core_ha/data/core_ha_checkpoint_store.dart';
import 'package:larenor/features/core_ha/domain/core_ha_activity_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _MemoryBackend implements CoreHaCheckpointBackend {
  final values = <String, String>{};
  final calls = <String>[];
  Future<void> Function()? afterRead;

  @override
  Future<String?> read(String key) async {
    calls.add('read:$key');
    final value = values[key];
    await afterRead?.call();
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    calls.add('write:$key');
    values[key] = value;
  }
}

ServerContext _context([String home = 'b']) => ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': home * 32,
});

CoreHaHistoryVerification _proof({
  int sequence = 2,
  String chain = 'c',
  String head = 'd',
  String checkpoint = 'checkpoint-2',
  bool compared = false,
}) => CoreHaHistoryVerification.fromJson(
  {
    'schemaVersion': 1,
    'scope': _context().toJson(),
    'chainId': chain * 32,
    'sequence': sequence,
    'headHash': head * 64,
    'checkpoint': checkpoint,
    'verified': true,
    'comparedCheckpoint': compared,
    'causalityVerified': false,
  },
  expectedContext: _context(),
  expectedComparison: compared,
);

void main() {
  test('first pin is scope-bound and never silently overwrites', () async {
    final backend = _MemoryBackend();
    final store = CoreHaCheckpointStore(
      backend: backend,
      clock: () => DateTime.utc(2026, 9, 10, 12),
    );

    final pinned = await store.pin(_context(), _proof(), isCurrent: () => true);
    expect(pinned.sequence, 2);
    expect(pinned.checkpoint, 'checkpoint-2');
    expect(await store.read(_context(), isCurrent: () => true), pinned);
    expect(await store.read(_context('e'), isCurrent: () => true), isNull);
    expect(
      () => store.pin(
        _context(),
        _proof(sequence: 3, checkpoint: 'checkpoint-3'),
        isCurrent: () => true,
      ),
      throwsA(
        isA<CoreHaCheckpointException>().having(
          (error) => error.code,
          'code',
          'already_pinned',
        ),
      ),
    );
    expect(
      (await store.read(_context(), isCurrent: () => true))?.checkpoint,
      'checkpoint-2',
    );
  });

  test(
    'rotation requires a matched, monotonic proof and exact prior pin',
    () async {
      final backend = _MemoryBackend();
      final store = CoreHaCheckpointStore(backend: backend);
      final pinned = await store.pin(
        _context(),
        _proof(),
        isCurrent: () => true,
      );

      for (final proof in [
        _proof(sequence: 3, checkpoint: 'checkpoint-3'),
        _proof(sequence: 1, checkpoint: 'checkpoint-1', compared: true),
        _proof(
          sequence: 3,
          chain: 'e',
          checkpoint: 'checkpoint-3',
          compared: true,
        ),
      ]) {
        expect(
          () => store.rotate(_context(), pinned, proof, isCurrent: () => true),
          throwsA(isA<CoreHaCheckpointException>()),
        );
      }
      expect(
        (await store.read(_context(), isCurrent: () => true))?.checkpoint,
        'checkpoint-2',
      );

      final rotated = await store.rotate(
        _context(),
        pinned,
        _proof(
          sequence: 3,
          head: 'e',
          checkpoint: 'checkpoint-3',
          compared: true,
        ),
        isCurrent: () => true,
      );
      expect(rotated.sequence, 3);
      expect(rotated.checkpoint, 'checkpoint-3');
      expect(rotated.revision, pinned.revision + 1);
    },
  );

  test('retirement after secure read stops a pin before its write', () async {
    final backend = _MemoryBackend();
    final store = CoreHaCheckpointStore(backend: backend);
    var current = true;
    backend.afterRead = () async => current = false;

    await expectLater(
      store.pin(_context(), _proof(), isCurrent: () => current),
      throwsA(
        isA<CoreHaCheckpointException>().having(
          (error) => error.code,
          'code',
          'retired',
        ),
      ),
    );
    expect(backend.calls.where((call) => call.startsWith('write:')), isEmpty);
    expect(backend.values, isEmpty);
  });

  test('malformed secure data fails closed without replacement', () async {
    final backend = _MemoryBackend();
    final store = CoreHaCheckpointStore(backend: backend);
    final key = CoreHaCheckpointStore.storageKey(_context());
    backend.values[key] = jsonEncode({'version': 1, 'checkpoint': 'forged'});

    await expectLater(
      store.read(_context(), isCurrent: () => true),
      throwsA(
        isA<CoreHaCheckpointException>().having(
          (error) => error.code,
          'code',
          'invalid_record',
        ),
      ),
    );
    expect(backend.values[key], contains('forged'));
    expect(backend.calls.where((call) => call.startsWith('write:')), isEmpty);
  });
}
