import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/ai_memory/data/server_ai_memory_api.dart';
import 'package:larenor/features/server/ai_memory/domain/server_ai_memory_models.dart';
import 'package:larenor/features/server/ai_memory/presentation/server_ai_memory_screen.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations_en.dart';

class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_MEMORY_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);
  test('legacy source kind remains visible beside its description', () {
    final l10n = AppLocalizationsEn();
    expect(
      serverAiMemorySourceLabel(
        l10n,
        const AiMemorySource('assistant', 'Imported receipt'),
      ),
      'Previously declared assistant source: Imported receipt',
    );
    expect(
      serverAiMemorySourceLabel(
        l10n,
        const AiMemorySource('manual', 'Larenor memory manager'),
      ),
      'Entered manually: Larenor memory manager',
    );
  });

  test(
    'actual Client → normal Core preserves manual and legacy provenance',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'AI memory gate',
      );
      expect(account.failure, isNull);
      await account.withSession((transport, session) async {
        final api = ServerAiMemoryApi(
          transport,
          session.accessToken,
          session.context!,
          session.user.id,
        );
        expect((await api.snapshot()).memories, isEmpty);
        final created = await api.remember(
          requestKey: 'client-memory-create-0001',
          content: 'Kitchen light prefers warm white',
          durationSeconds: 3600,
        );
        expect(created.source.kind, 'manual');
        expect(created.source.description, 'Larenor memory manager');
        expect(created.learnedBy, 'admin');
        expect(created.retention.durationSeconds, 3600);
        expect((await api.search('warm')).single.id, created.id);

        final corrected = await api.correct(
          created,
          requestKey: 'client-memory-correct-0002',
          content: 'Kitchen light prefers neutral white',
          durationSeconds: 86400,
        );
        expect(corrected.source.kind, 'manual');
        expect(corrected.learnedBy, 'admin');
        expect(await api.search('warm'), isEmpty);
        expect((await api.search('neutral')).single.revision, 2);
        final exported = await api.exportBackup();
        expect(exported.records.single.source.kind, 'manual');
        expect(exported.records.single.learnedBy, 'admin');

        await api.forget(corrected, 'client-memory-forget-0003');
        expect(await api.search('neutral'), isEmpty);
        final manualRecord = exported.records.single.toJson()
          ..['memoryId'] = '6' * 32;
        final manualBackup = AiMemoryBackup.fromJson({
          'schemaVersion': 1,
          'records': [manualRecord],
          'tombstones': <Object?>[],
        });
        final restored = await api.restoreBackup(
          manualBackup,
          requestKey: 'client-memory-restore-0004',
        );
        expect(restored.restoredCount, 1);
        expect(restored.blockedCount, 0);
        final restoredRecord = (await api.search('neutral')).single;
        expect(restoredRecord.id, '6' * 32);
        expect(restoredRecord.source.kind, 'manual');
        expect(restoredRecord.learnedBy, 'admin');

        final claimed = Map<String, Object>.from(manualRecord)
          ..['memoryId'] = '7' * 32
          ..['source'] = {
            'schemaVersion': 1,
            'kind': 'assistant',
            'description': 'Claimed assistant receipt',
          };
        final legacy = AiMemoryBackup.fromJson({
          'schemaVersion': 1,
          'records': [claimed],
          'tombstones': <Object?>[],
        });
        expect(legacy.records.single.source.kind, 'assistant');
        expect(
          (legacy.records.single.toJson()['source'] as Map)['kind'],
          'assistant',
        );
        await expectLater(
          api.restoreBackup(
            legacy,
            requestKey: 'client-memory-restore-forged-0005',
          ),
          throwsA(
            isA<LarenorServerException>().having(
              (error) => error.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        expect((await api.search('neutral')).single.id, '6' * 32);
      });
    },
    skip: url == null ? 'Requires explicit isolated normal Core runner' : false,
  );
}
