import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/game_streaming/data/android_game_stream_v2_port.dart';
import 'package:larenor/features/game_streaming/data/core_game_stream_api.dart';
import 'package:larenor/features/game_streaming/data/game_stream_recovery_store.dart';

final class _MemoryBackend implements GameStreamRecoveryBackend {
  String? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String next) async => value = next;
}

GameStreamRecoveryScope scope([String family = 'd']) => GameStreamRecoveryScope(
  coreId: 'a' * 32,
  homeId: 'b' * 32,
  accountId: 'c' * 32,
  familyId: family * 32,
);

GameStreamRecoveryRecord record() => GameStreamRecoveryRecord(
  scope: scope(),
  sessionId: 'e' * 32,
  sessionRevision: 3,
  commandId: 'f' * 32,
  intent: 'stream',
  dispatchGrant: '1' * 32,
);

AndroidGameStreamAuthorityV2 authority() => AndroidGameStreamAuthorityV2(
  clientInstanceId: '0' * 32,
  coreId: 'a' * 32,
  homeId: 'b' * 32,
  accountId: 'c' * 32,
  familyId: 'd' * 32,
  accountRevision: 7,
  pinRevision: 2,
  pinConfigured: true,
  pinUnlocked: true,
  routeRevision: 3,
  lifecycleRevision: 4,
  idleRevision: 5,
  interactionRevision: 6,
);

void main() {
  test(
    'pending one-use grant is private, scope-bound and exact-clear only',
    () async {
      final backend = _MemoryBackend();
      final store = GameStreamRecoveryStore(backend: backend);
      final pending = record();
      await store.write(pending);
      expect('$pending', isNot(contains(pending.dispatchGrant)));
      expect((await store.read(scope()))?.commandId, pending.commandId);
      expect(await store.read(scope('9')), isNull);
      expect(backend.value, isNotNull);

      final fenced = pending.withNativeRetired();
      await store.write(fenced);
      final restored = await store.readStored();
      expect(restored, isA<GameStreamRecoveryRecord>());
      expect((restored! as GameStreamRecoveryRecord).nativeRetired, isTrue);

      final changed = GameStreamRecoveryRecord(
        scope: pending.scope,
        sessionId: pending.sessionId,
        sessionRevision: pending.sessionRevision,
        commandId: '2' * 32,
        intent: pending.intent,
        dispatchGrant: pending.dispatchGrant,
      );
      await store.clearExact(changed);
      expect(await store.read(scope()), isNotNull);
      await store.clearExact(fenced);
      expect(await store.read(scope()), isNull);
    },
  );

  test(
    'malformed or oversized recovery state is retained and blocks replacement',
    () async {
      final backend = _MemoryBackend()..value = '{"dispatchGrant":"secret"}';
      final store = GameStreamRecoveryStore(backend: backend);
      await expectLater(store.read(scope()), throwsException);
      expect(backend.value, '{"dispatchGrant":"secret"}');

      backend.value = 'x' * 8193;
      await expectLater(store.read(scope()), throwsException);
      expect(backend.value, 'x' * 8193);
    },
  );

  test(
    'legacy host ceilings are validated then discarded on recovery',
    () async {
      final backend = _MemoryBackend();
      final store = GameStreamRecoveryStore(backend: backend);
      final pending = GameStreamRevocationPrepareRecovery(
        scope: scope(),
        accountRevision: 1,
        requestKey: 'legacy-recovery-1',
        host: CoreGameStreamHost.recovery(
          id: 'e' * 32,
          revision: 1,
          pairingRevision: 1,
          catalogRevision: 1,
          name: 'Legacy host',
          codecs: const ['h264'],
        ),
      );
      await store.writeAny(pending);
      final encoded = jsonDecode(backend.value!) as Map<String, dynamic>;
      final payload = encoded['payload']! as Map<String, dynamic>;
      final host = payload['host']! as Map<String, dynamic>;
      host.addAll({'maxWidth': 3840, 'maxHeight': 2160, 'maxFps': 120});
      backend.value = jsonEncode(encoded);

      final recovered = await store.readAny(scope());
      expect(recovered, isA<GameStreamRevocationPrepareRecovery>());
      final current = recovered! as GameStreamRevocationPrepareRecovery;
      expect(current.host.name, 'Legacy host');
      await store.writeAny(current);
      expect(backend.value, isNot(contains('maxWidth')));
    },
  );

  test(
    'pending session bind retirement is durable and exact-clear only',
    () async {
      final backend = _MemoryBackend();
      final store = GameStreamRecoveryStore(backend: backend);
      final pending = GameStreamSessionBindRecovery(
        scope: scope(),
        accountRevision: 7,
        sessionId: '3' * 32,
        sessionRevision: 1,
        retireRequestKey: 'retire-bind-12345678',
      );

      await store.writeAny(pending);
      final restored = await store.readAny(scope());
      expect(restored, isA<GameStreamSessionBindRecovery>());
      final exact = restored! as GameStreamSessionBindRecovery;
      expect(exact.retireRequestKey, pending.retireRequestKey);
      expect(exact.nativeRetired, isFalse);

      final fenced = exact.withNativeRetired();
      await store.writeAny(fenced);
      expect(
        (await store.readAny(
          scope(),
        ) as GameStreamSessionBindRecovery).nativeRetired,
        isTrue,
      );
      await store.clearAny(pending);
      expect(await store.readAny(scope()), isNotNull);

      final differentRevision = GameStreamSessionBindRecovery(
        scope: pending.scope,
        accountRevision: pending.accountRevision,
        sessionId: pending.sessionId,
        sessionRevision: 2,
        retireRequestKey: pending.retireRequestKey,
      );
      await store.clearAny(differentRevision);
      expect(await store.readAny(scope()), isNotNull);
      await store.clearAny(fenced);
      expect(await store.readAny(scope()), isNull);
    },
  );

  test('causal stop cleanup persists exact retirement identities', () async {
    final backend = _MemoryBackend();
    final store = GameStreamRecoveryStore(backend: backend);
    final pending = GameStreamStopCleanupRecovery(
      scope: scope(),
      accountRevision: 7,
      sessionId: '3' * 32,
      sessionRevision: 1,
      commandId: '4' * 32,
      retireRequestKey: 'retire-stop-12345678',
    );

    await store.writeAny(pending);
    final restored = await store.readAny(scope());
    expect(restored, isA<GameStreamStopCleanupRecovery>());
    final exact = restored! as GameStreamStopCleanupRecovery;
    expect(exact.commandId, pending.commandId);
    expect(exact.sessionRevision, 1);
    expect(exact.nativeRetired, isFalse);
    expect('$exact ${backend.value}', isNot(contains('dispatchGrant')));

    final fenced = exact.withNativeRetired();
    await store.writeAny(fenced);
    expect(
      (await store.readAny(
        scope(),
      ) as GameStreamStopCleanupRecovery).nativeRetired,
      isTrue,
    );
    await store.clearAny(exact);
    expect(await store.readAny(scope()), isNotNull);
    await store.clearAny(fenced);
    expect(await store.readAny(scope()), isNull);
  });

  test(
    'pairing authority retirement and issued grant survive restart exactly',
    () async {
      final backend = _MemoryBackend();
      final store = GameStreamRecoveryStore(backend: backend);
      final pending = GameStreamPairingRecovery(
        scope: scope(),
        authority: authority(),
        accountRevision: 7,
        pairingId: '3' * 32,
        pairingRevision: 1,
        pairingGrant: '4' * 32,
        expiresAtMillis: 1800000000000,
      ).withPairingDispatched().withAuthorityRetirementPending();

      await store.writeAny(pending);
      final restored = await store.readStored();
      expect(restored, isA<GameStreamPairingRecovery>());
      final exact = restored! as GameStreamPairingRecovery;
      expect(exact.pairingGrant, pending.pairingGrant);
      expect(exact.authority.routeRevision, 3);
      expect(exact.pairingDispatched, isTrue);
      expect(exact.authorityRetirementPending, isTrue);
      expect(exact.authorityRetired, isFalse);

      final retired = exact.withAuthorityRetired();
      await store.writeAny(retired);
      final finalRecord = await store.readStored();
      expect(
        (finalRecord! as GameStreamPairingRecovery).authorityRetired,
        isTrue,
      );
      expect(backend.value, contains('"pairingGrant":"${'4' * 32}"'));
    },
  );
}
