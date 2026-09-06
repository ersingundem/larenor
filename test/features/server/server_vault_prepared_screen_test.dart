import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/backup/presentation/backup_screen.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/presentation/server_vault_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/backup_test_storage.dart';
import 'server_vault_test_support.dart';

class _Harness {
  final api = VaultApi()
    ..value = ServerVault(
      revision: 7,
      snapshot: BackupSnapshot.fromJson({
        'version': 2,
        'createdAt': '2026-09-06T00:00:00.000Z',
        'groups': {
          'settings': {'appearance': 'dark'},
          'privacy': {
            'version': 1,
            'entityIds': <String>[],
            'reviewRequired': false,
          },
        },
      }),
    );
  final storage = MemoryBackupStorage(
    preferences: {'appearance': 'light'},
    secrets: {'settings_pin': 'unrelated-pin-sentinel'},
  );
  late final ServerAccountController account;
  int opens = 0, disposals = 0;

  Future<void> mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    account = ServerAccountController(
      store: VaultAccountStore(),
      apiFactory: (_) => api,
    );
    await account.initialize();
    tester.view.physicalSize = const Size(800, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final probe = Provider<int>((ref) {
      opens++;
      ref.onDispose(() => disposals++);
      return opens;
    });
    await tester.pumpWidget(
      ConfigurationScope(
        child: ProviderScope(
          overrides: [
            serverAccountControllerProvider.overrideWithValue(account),
            backupRepositoryProvider.overrideWithValue(
              BackupRepository(storage: storage),
            ),
          ],
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(probe);
                return const ServerVaultScreen(freshInstall: true);
              },
            ),
          ),
        ),
      ),
    );
    await flush(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      account.dispose();
    });
    await tap(tester, 'server-vault-replace');
    await tap(tester, 'server-vault-review');
    expect(find.text('Revision 7'), findsOneWidget);
    expect(storage.writes, isEmpty);
    await tap(tester, 'server-vault-apply');
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
  }

  Future<void> accept(WidgetTester tester) async {
    await tap(tester, 'server-vault-confirm');
    await flush(tester);
  }
}

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await flush(tester);
}

void main() {
  testWidgets('Vault hands off a typed v2 restore and replaces runtime providers', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await h.accept(tester);
    expect(h.storage.preferences['appearance'], 'dark');
    expect(h.storage.writes, contains('secret:backup_restore_journal_v2'));
    expect(h.storage.writes,
        isNot(contains('secret:${BackupRepository.restoreJournalKey}')));
    expect(h.disposals, 1);
    expect(h.opens, 2);
    expect(h.api.reads, 2);
    expect(h.api.writes, 0);
    expect(h.storage.secrets['settings_pin'], 'unrelated-pin-sentinel');
    expect(tester.takeException(), isNull);
  });

  testWidgets('target changed under Vault confirmation has zero writes', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    h.storage.preferences['appearance'] = 'system';
    await h.accept(tester);
    expect(h.storage.preferences['appearance'], 'system');
    expect(h.storage.writes, isEmpty);
    expect(h.disposals, 0);
    expect(h.api.writes, 0);
  });

  testWidgets('persisted source change cannot retarget a Vault confirmation', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await SharedPreferencesHomeSourceStore().write(HomeSource.verifiedCore);
    await h.accept(tester);
    expect(h.storage.preferences['appearance'], 'light');
    expect(h.storage.writes, isEmpty);
    expect(h.disposals, 0);
    expect(h.api.writes, 0);
  });
}
