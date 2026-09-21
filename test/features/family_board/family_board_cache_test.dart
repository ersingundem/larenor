import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/family_board/data/family_board_cache.dart';

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
