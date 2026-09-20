import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/core_ha/data/core_ha_event_checkpoint_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _MemoryBackend implements CoreHaEventCheckpointBackend {
  final values = <String, String>{};
  int writes = 0;
  Future<void> Function()? afterRead;

  @override
  Future<String?> read(String key) async {
    final value = values[key];
    await afterRead?.call();
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }
}

ServerContext _context([String home = 'b']) => ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': home * 32,
});

CoreHaEventCheckpointScope _scope({
  String resource = 'c',
  String actor = 'fixture',
  ServerRole role = ServerRole.member,
}) => CoreHaEventCheckpointScope(
  context: _context(),
  resourceId: resource * 32,
  actorId: actor,
  role: role,
);

void main() {
  test('checkpoint is scope-bound and advances monotonically', () async {
    final backend = _MemoryBackend();
    final store = CoreHaEventCheckpointStore(
      backend: backend,
      clock: () => DateTime.utc(2026, 9, 20, 12),
    );
    final scope = _scope();

    final first = await store.advance(
      scope,
      before: null,
      chainId: 'd' * 32,
      headSequence: 2,
      isCurrent: () => true,
    );
    expect(first.headSequence, 2);
    expect(first.revision, 1);
    expect(await store.read(scope, isCurrent: () => true), first);
    expect(
      await store.read(_scope(actor: 'other'), isCurrent: () => true),
      isNull,
    );

    final advanced = await store.advance(
      scope,
      before: first,
      chainId: 'd' * 32,
      headSequence: 3,
      isCurrent: () => true,
    );
    expect(advanced.headSequence, 3);
    expect(advanced.revision, 2);
    expect(backend.writes, 2);

    await expectLater(
      store.advance(
        scope,
        before: advanced,
        chainId: 'd' * 32,
        headSequence: 2,
        isCurrent: () => true,
      ),
      throwsA(
        isA<CoreHaEventCheckpointException>().having(
          (error) => error.code,
          'code',
          'rollback',
        ),
      ),
    );
  });

  test('chain replacement requires explicit acceptance', () async {
    final backend = _MemoryBackend();
    final store = CoreHaEventCheckpointStore(backend: backend);
    final scope = _scope();
    final first = await store.advance(
      scope,
      before: null,
      chainId: 'd' * 32,
      headSequence: 2,
      isCurrent: () => true,
    );

    await expectLater(
      store.advance(
        scope,
        before: first,
        chainId: 'e' * 32,
        headSequence: 1,
        isCurrent: () => true,
      ),
      throwsA(
        isA<CoreHaEventCheckpointException>().having(
          (error) => error.code,
          'code',
          'chain_changed',
        ),
      ),
    );
    expect(await store.read(scope, isCurrent: () => true), first);

    final replaced = await store.advance(
      scope,
      before: first,
      chainId: 'e' * 32,
      headSequence: 1,
      allowChainReplacement: true,
      isCurrent: () => true,
    );
    expect(replaced.chainId, 'e' * 32);
    expect(replaced.revision, 2);
  });

  test(
    'retirement and malformed records fail closed without a write',
    () async {
      final backend = _MemoryBackend();
      final store = CoreHaEventCheckpointStore(backend: backend);
      final scope = _scope();
      var current = true;
      backend.afterRead = () async => current = false;
      await expectLater(
        store.advance(
          scope,
          before: null,
          chainId: 'd' * 32,
          headSequence: 1,
          isCurrent: () => current,
        ),
        throwsA(
          isA<CoreHaEventCheckpointException>().having(
            (error) => error.code,
            'code',
            'retired',
          ),
        ),
      );
      expect(backend.writes, 0);

      current = true;
      backend.afterRead = null;
      backend.values[CoreHaEventCheckpointStore.storageKey(scope)] = jsonEncode(
        {'version': 1, 'chainId': 'forged'},
      );
      await expectLater(
        store.read(scope, isCurrent: () => true),
        throwsA(
          isA<CoreHaEventCheckpointException>().having(
            (error) => error.code,
            'code',
            'invalid_record',
          ),
        ),
      );
      expect(backend.writes, 0);
    },
  );
}
