import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/family_board/data/family_board_cache.dart';
import 'package:larenor/features/family_board/domain/family_board_models.dart';

import 'family_board_controller_test.dart';

class MemoryBackend implements FamilyBoardCacheBackend {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

final class DelayedWriteBackend extends MemoryBackend {
  final gate = Completer<void>();
  @override
  Future<void> write(String key, String value) async {
    await super.write(key, value);
    await gate.future;
  }
}

void main() {
  test('secure cache round trips only the exact authority scope', () async {
    final backend = MemoryBackend();
    final cache = SecureFamilyBoardCache(backend: backend);
    await cache.write(snap(), isCurrent: () => true);
    expect(
      (await cache.read(binding(), isCurrent: () => true))!.cards.single.text,
      'Film gecesi',
    );
    expect(
      await cache.read(binding(memberRevision: 2), isCurrent: () => true),
      isNull,
    );
    expect(backend.values.keys.single, isNot(contains(core)));
    expect(backend.values.keys.single, isNot(contains(account)));
  });

  test('invalid and oversized cache is deleted and never displayed', () async {
    final backend = MemoryBackend();
    final cache = SecureFamilyBoardCache(backend: backend);
    await cache.write(snap(), isCurrent: () => true);
    final key = backend.values.keys.single;
    backend.values[key] = '{"tampered":true}';
    expect(await cache.read(binding(), isCurrent: () => true), isNull);
    expect(backend.values, isEmpty);
  });

  test(
    'pending command is exact scoped durable and cleared by request id',
    () async {
      final backend = MemoryBackend();
      final cache = SecureFamilyBoardCache(backend: backend);
      final command = FamilyBoardCommand.append(
        '8' * 32,
        1,
        BoardCard(
          id: '7' * 32,
          text: 'Pending private card',
          x: 1,
          y: 2,
          color: 'yellow',
        ),
      );

      await cache.writePending(binding(), command, isCurrent: () => true);
      final restored = await cache.readPending(
        binding(),
        isCurrent: () => true,
      );
      expect(restored?.toJson(), command.toJson());
      await expectLater(
        cache.clearPending(binding(), '9' * 32, isCurrent: () => true),
        throwsA(isA<FamilyBoardException>()),
      );
      expect(
        await cache.readPending(binding(), isCurrent: () => true),
        isNotNull,
      );
      await cache.clearPending(
        binding(),
        command.requestId,
        isCurrent: () => true,
      );
      expect(await cache.readPending(binding(), isCurrent: () => true), isNull);
    },
  );

  test(
    'invalid pending journal fails closed without deleting evidence',
    () async {
      final backend = MemoryBackend();
      final cache = SecureFamilyBoardCache(backend: backend);
      await cache.writePending(
        binding(),
        FamilyBoardCommand.append(
          '8' * 32,
          1,
          BoardCard(
            id: '7' * 32,
            text: 'Pending private card',
            x: 1,
            y: 2,
            color: 'yellow',
          ),
        ),
        isCurrent: () => true,
      );
      final key = backend.values.keys.single;
      backend.values[key] = '{corrupt';

      await expectLater(
        cache.readPending(binding(), isCurrent: () => true),
        throwsA(
          isA<FamilyBoardException>().having(
            (error) => error.code,
            'code',
            'invalid_cache',
          ),
        ),
      );
      expect(backend.values[key], '{corrupt');
    },
  );

  test(
    'pending effect blocks changed authority without changing evidence',
    () async {
      final backend = MemoryBackend();
      final cache = SecureFamilyBoardCache(backend: backend);
      final command = FamilyBoardCommand.append(
        '8' * 32,
        1,
        BoardCard(
          id: '7' * 32,
          text: 'Authority-bound pending card',
          x: 1,
          y: 2,
          color: 'yellow',
        ),
      );
      await cache.writePending(binding(), command, isCurrent: () => true);
      final evidence = Map<String, String>.from(backend.values);

      await expectLater(
        cache.readPending(binding(memberRevision: 2), isCurrent: () => true),
        throwsA(
          isA<FamilyBoardException>().having(
            (error) => error.code,
            'code',
            'invalid_cache',
          ),
        ),
      );
      expect(backend.values, evidence);
    },
  );

  test('route or lifecycle retirement rejects late cache completion', () async {
    final backend = MemoryBackend();
    final cache = SecureFamilyBoardCache(backend: backend);
    var current = true;
    await cache.write(snap(), isCurrent: () => current);
    current = false;
    expect(
      () => cache.read(binding(), isCurrent: () => current),
      throwsA(isA<Exception>()),
    );
  });

  test(
    'late secure write is removed after lifecycle authority changes',
    () async {
      final backend = DelayedWriteBackend();
      final cache = SecureFamilyBoardCache(backend: backend);
      var current = true;
      final operation = cache.write(snap(), isCurrent: () => current);
      await Future<void>.delayed(Duration.zero);
      current = false;
      backend.gate.complete();
      await expectLater(operation, throwsA(isA<Exception>()));
      expect(backend.values, isEmpty);
    },
  );
}
