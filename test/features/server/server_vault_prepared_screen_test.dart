import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/backup/presentation/backup_screen.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/presentation/server_vault_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/presentation/idle_gate.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/backup_test_storage.dart';
import '../home_resources/home_resources_tablet_test.dart' show loadFonts;
import '../../support/restore_dialog_geometry.dart';
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
  late final VaultAccountStore accountStore;
  final sourceStore = SharedPreferencesHomeSourceStore();
  HomeSessionController? home;
  int opens = 0, disposals = 0;

  Future<void> mount(
    WidgetTester tester, {
    bool core = false,
    bool protected = false,
    String language = 'en',
    double width = 800,
    double scale = 1,
    bool openConfirmation = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (core)
        SharedPreferencesHomeSourceStore.key: HomeSource.verifiedCore.name,
    });
    FlutterSecureStorage.setMockInitialValues({
      if (protected) 'settings_pin': '123456',
    });
    accountStore = VaultAccountStore();
    account = ServerAccountController(
      store: accountStore,
      apiFactory: (_) => api,
    );
    await account.initialize();
    if (core) {
      home = HomeSessionController(store: sourceStore, account: account);
      await home!.initialize();
      home!.runtimeMounted(home!.runtimeIdentity);
    }
    tester.view.physicalSize = Size(width, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final probe = Provider<int>((_) => 0);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(account),
          serverSessionStoreProvider.overrideWithValue(accountStore),
          homeSessionControllerProvider.overrideWithValue(home),
          backupRepositoryProvider.overrideWithValue(
            BackupRepository(
              storage: storage,
              recoverySourceStore: sourceStore,
              recoverySessionStore: accountStore,
            ),
          ),
        ],
        child: ConfigurationScope(
          child: ProviderScope(
            overrides: [
              probe.overrideWith((ref) {
                opens++;
                ref.onDispose(() => disposals++);
                return opens;
              }),
            ],
            child: CupertinoApp(
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: IdleGate(child: child!),
              ),
              home: Consumer(
                builder: (context, ref, _) {
                  ref.watch(probe);
                  return protected
                      ? const SettingsGateScreen(
                          initialDestination:
                              SettingsGateDestination.serverAccount,
                        )
                      : const ServerVaultScreen(freshInstall: true);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await flush(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      home?.dispose();
      account.dispose();
    });
    if (protected) {
      expect(find.byType(ServerVaultScreen), findsNothing);
      expect(api.reads, 0);
      await tester.enterText(find.byType(CupertinoTextField), '123456');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await flush(tester);
      await tap(tester, 'server-vault');
    }
    await tap(tester, 'server-vault-replace');
    await tap(tester, 'server-vault-review');
    if (!openConfirmation) return;
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ServerVaultScreen)),
    );
    expect(find.text(l10n.serverVaultRevision(7)), findsOneWidget);
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

int _labelCount(SemanticsNode node, String label) {
  var count = node.label == label ? 1 : 0;
  node.visitChildren((child) {
    count += _labelCount(child, label);
    return true;
  });
  return count;
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'Vault effective dialog target and painted label $language $width ${scale}x',
          (tester) async {
            await loadFonts(tester);
            final semantics = tester.ensureSemantics();
            try {
              final h = _Harness();
              await h.mount(
                tester,
                language: language,
                width: width,
                scale: scale,
              );
              final l10n = AppLocalizations.of(
                tester.element(find.byType(CupertinoAlertDialog)),
              );
              final cancel = find.widgetWithText(
                CupertinoDialogAction,
                l10n.commonCancel,
              );
              final failures = restoreDialogGeometryFailures(
                tester,
                labels: [l10n.commonCancel, l10n.backupApply],
                cancel: cancel,
              );
              Focus.of(
                tester.element(
                  find
                      .descendant(of: cancel, matching: find.byType(Text))
                      .first,
                ),
              ).requestFocus();
              await flush(tester);
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await flush(tester);
              expect(find.byType(CupertinoAlertDialog), findsNothing);
              expect(h.storage.writes, isEmpty);
              expect(h.api.writes, 0);
              expect(h.disposals, 0);
              expect(tester.takeException(), isNull);
              expect(failures, isEmpty);
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }
  }

  for (final language in ['en', 'tr']) {
    for (final width in [320.0, 600.0, 1280.0]) {
      testWidgets('Vault confirmation semantics $language $width at 2x', (
        tester,
      ) async {
        await loadFonts(tester);
        final semantics = tester.ensureSemantics();
        try {
          final h = _Harness();
          await h.mount(tester, language: language, width: width, scale: 2);
          final dialog = find.byType(CupertinoAlertDialog);
          final l10n = AppLocalizations.of(tester.element(dialog));
          for (final label in [l10n.commonCancel, l10n.backupApply]) {
            final action = find.widgetWithText(CupertinoDialogAction, label);
            await tester.ensureVisible(action);
            await flush(tester);
            final rect = tester.getRect(action);
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(width));
            final node = tester.getSemantics(action);
            expect(node.flagsCollection.isButton, isTrue);
            expect(node.label, label);
            expect(_labelCount(node.owner!.rootSemanticsNode!, label), 1);
          }
          expect(tester.takeException(), isNull);
          await tester.tap(
            find.widgetWithText(CupertinoDialogAction, l10n.commonCancel),
          );
          await flush(tester);
          expect(find.byType(CupertinoAlertDialog), findsNothing);
          expect(h.storage.writes, isEmpty);
          expect(h.api.writes, 0);
          expect(h.api.reads, 1);
          expect(h.disposals, 0);
        } finally {
          semantics.dispose();
        }
      });
      testWidgets('Vault confirmation keyboard cancel $language $width at 2x', (
        tester,
      ) async {
        await loadFonts(tester);
        final h = _Harness();
        await h.mount(tester, language: language, width: width, scale: 2);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await flush(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await flush(tester);
        expect(find.byType(CupertinoAlertDialog), findsNothing);
        expect(h.storage.writes, isEmpty);
        expect(h.api.writes, 0);
        expect(h.api.reads, 1);
        expect(h.disposals, 0);
        expect(h.storage.preferences['appearance'], 'light');
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final dark in [false, true]) {
    testWidgets(
      'Vault modal visible keyboard focus and reverse traversal dark=$dark',
      (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue = dark
            ? Brightness.dark
            : Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await loadFonts(tester);
        final h = _Harness();
        await h.mount(tester, language: 'tr', width: 320, scale: 2);
        final l10n = AppLocalizations.of(
          tester.element(find.byType(CupertinoAlertDialog)),
        );
        final cancel = find.widgetWithText(
          CupertinoDialogAction,
          l10n.commonCancel,
        );
        final confirm = find.byKey(const ValueKey('server-vault-confirm'));
        void expectFocused(Finder action) {
          final focused = find.descendant(
            of: action,
            matching: find.byWidgetPredicate((widget) {
              if (widget is! Container || widget.decoration is! BoxDecoration) {
                return false;
              }
              final border = (widget.decoration! as BoxDecoration).border;
              return border is Border &&
                  border.top.color.a > 0 &&
                  border.top.width >= 2;
            }),
          );
          expect(focused, findsOneWidget);
        }

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await flush(tester);
        expectFocused(cancel);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await flush(tester);
        expectFocused(confirm);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await flush(tester);
        expectFocused(cancel);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await flush(tester);
        expect(find.byType(CupertinoAlertDialog), findsNothing);
        expect(h.storage.writes, isEmpty);
        expect(h.api.reads, 1);
        expect(h.api.writes, 0);
        expect(h.disposals, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Vault modal semantic cancel has zero effects', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final h = _Harness();
      await h.mount(tester, scale: 2);
      final cancel = find.widgetWithText(CupertinoDialogAction, 'Cancel');
      final node = tester.getSemantics(cancel);
      tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
        node.id,
        SemanticsAction.tap,
      );
      await flush(tester);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(h.storage.writes, isEmpty);
      expect(h.api.writes, 0);
      expect(h.api.reads, 1);
      expect(h.disposals, 0);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('Vault modal keyboard confirm uses the existing typed handoff', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, scale: 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await flush(tester);
    expect(h.storage.preferences['appearance'], 'dark');
    expect(h.storage.writes, contains('secret:backup_restore_journal_v2'));
    expect(h.api.reads, 2);
    expect(h.api.writes, 0);
    expect(h.disposals, 1);
    expect(h.opens, 2);
  });

  testWidgets(
    'Vault modal retained keyboard action cannot survive native focus retirement',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, scale: 2);
      final confirm = find.byKey(const ValueKey('server-vault-confirm'));
      final actions = tester.widget<Actions>(
        find.descendant(of: confirm, matching: find.byType(Actions)).first,
      );
      final retained =
          actions.actions[ActivateIntent]! as Action<ActivateIntent>;
      tester.binding.handleViewFocusChanged(
        ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ViewFocusState.unfocused,
          direction: ViewFocusDirection.undefined,
        ),
      );
      const ActionDispatcher().invokeAction(retained, const ActivateIntent());
      await flush(tester);
      tester.binding.handleViewFocusChanged(
        ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ViewFocusState.focused,
          direction: ViewFocusDirection.undefined,
        ),
      );
      await flush(tester);
      const ActionDispatcher().invokeAction(retained, const ActivateIntent());
      await flush(tester);
      expect(h.storage.writes, isEmpty);
      expect(h.api.reads, 1);
      expect(h.api.writes, 0);
      expect(h.disposals, 0);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Vault hands off a typed v2 restore and replaces runtime providers',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.accept(tester);
      expect(h.storage.preferences['appearance'], 'dark');
      expect(h.storage.writes, contains('secret:backup_restore_journal_v2'));
      expect(
        h.storage.writes,
        isNot(contains('secret:${BackupRepository.restoreJournalKey}')),
      );
      expect(h.disposals, 1);
      expect(h.opens, 2);
      expect(h.api.reads, 2);
      expect(h.api.writes, 0);
      expect(h.storage.secrets['settings_pin'], 'unrelated-pin-sentinel');
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets(
    'remote revision drift under confirmation requires another review',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      h.api.value = ServerVault(revision: 8, snapshot: h.api.value.snapshot);
      await h.accept(tester);
      expect(h.api.reads, 2);
      expect(h.api.writes, 0);
      expect(h.storage.writes, isEmpty);
      expect(h.disposals, 0);
      expect(find.textContaining('The server vault changed.'), findsOneWidget);
    },
  );

  testWidgets('fresh-install persisted PIN addition rejects old confirmation', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '654321'});
    await h.accept(tester);
    expect(h.storage.writes, isEmpty);
    expect(h.disposals, 0);
    expect(h.storage.preferences['appearance'], 'light');
  });

  testWidgets(
    'logout while final Vault GET waits cannot hand off the old account',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      h.api.pendingRead = Completer();
      await tap(tester, 'server-vault-confirm');
      expect(h.api.reads, 2);
      await h.account.signOut();
      h.api.pendingRead!.complete(h.api.value);
      await flush(tester);
      expect(h.storage.writes, isEmpty);
      expect(h.disposals, 0);
      expect(h.account.session, isNull);
    },
  );

  testWidgets(
    'cancel consumes the review and retained confirmation cannot restore',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final old = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('server-vault-confirm')),
          )
          .onPressed!;
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
      await flush(tester);
      old();
      await flush(tester);
      expect(h.storage.writes, isEmpty);
      expect(h.api.reads, 1);
      expect(find.byKey(const ValueKey('server-vault-apply')), findsNothing);
    },
  );

  testWidgets(
    'native focus retirement closes Vault approval and invalidates captured action',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final old = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('server-vault-confirm')),
          )
          .onPressed!;
      tester.binding.handleViewFocusChanged(
        ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ViewFocusState.unfocused,
          direction: ViewFocusDirection.undefined,
        ),
      );
      await flush(tester);
      tester.binding.handleViewFocusChanged(
        ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ViewFocusState.focused,
          direction: ViewFocusDirection.undefined,
        ),
      );
      await flush(tester);
      old();
      await flush(tester);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(h.storage.writes, isEmpty);
      expect(h.api.reads, 1);
    },
  );

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        'Core PIN-gated Vault restore $language ${width}px at 2x keeps scoped authority',
        (tester) async {
          final h = _Harness();
          await h.mount(
            tester,
            core: true,
            protected: true,
            language: language,
            width: width,
            scale: 2,
          );
          final before = h.accountStore.value!.encodeStorage();
          await h.accept(tester);
          expect(h.storage.preferences['appearance'], 'dark');
          expect(
            h.storage.writes,
            contains('secret:backup_restore_journal_v2'),
          );
          expect(h.accountStore.value!.encodeStorage(), before);
          expect(h.home!.source, HomeSource.verifiedCore);
          expect(h.disposals, 1);
          expect(h.opens, 2);
          expect(find.byType(ServerVaultScreen), findsNothing);
          expect(find.byType(CupertinoTextField), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'persisted Core session replacement under approval cannot restore',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, core: true);
      h.accountStore.value = vaultSession();
      await h.accept(tester);
      expect(h.storage.writes, isEmpty);
      expect(h.disposals, 0);
      expect(h.storage.preferences['appearance'], 'light');
    },
  );

  testWidgets(
    'Core Direct groups show the target restriction without credential reads',
    (tester) async {
      final h = _Harness();
      h.api.value = ServerVault(revision: 7, snapshot: vaultSnapshot());
      await h.mount(tester, core: true, openConfirmation: false);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ServerVaultScreen)),
      );
      expect(find.text(l10n.backupRestoreDirectTarget), findsOneWidget);
      expect(find.text(l10n.serverVaultReadFailed), findsNothing);
      expect(h.storage.reads, isEmpty);
      expect(h.storage.writes, isEmpty);
      expect(h.api.reads, 1);
      expect(h.api.writes, 0);
      expect(find.byKey(const ValueKey('server-vault-apply')), findsNothing);
    },
  );

  for (final replacement in [
    'account',
    'repository',
    'container',
    'modal repository',
  ]) {
    testWidgets('retained Vault state rejects $replacement replacement', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final apiA = VaultApi(), apiB = VaultApi();
      final accountA = ServerAccountController(
        store: VaultAccountStore(),
        apiFactory: (_) => apiA,
      );
      final accountB = ServerAccountController(
        store: VaultAccountStore(),
        apiFactory: (_) => apiB,
      );
      await accountA.initialize();
      await accountB.initialize();
      final storage = MemoryBackupStorage(preferences: {'appearance': 'light'});
      final otherStorage = MemoryBackupStorage(
        preferences: {'appearance': 'system'},
      );
      final repository = BackupRepository(storage: storage);
      ProviderContainer container(
        ServerAccountController account,
        BackupRepository repository,
      ) => ProviderContainer(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(account),
          backupRepositoryProvider.overrideWithValue(repository),
        ],
      );
      final a = container(accountA, repository);
      final b = container(
        replacement == 'account' ? accountB : accountA,
        replacement.contains('repository')
            ? BackupRepository(storage: otherStorage)
            : repository,
      );
      final selected = ValueNotifier(a);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        selected.dispose();
        a.dispose();
        b.dispose();
        accountA.dispose();
        accountB.dispose();
      });
      final screenKey = GlobalKey();
      tester.view.physicalSize = const Size(800, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ValueListenableBuilder<ProviderContainer>(
            valueListenable: selected,
            builder: (_, container, _) => UncontrolledProviderScope(
              container: container,
              child: ServerVaultScreen(key: screenKey, freshInstall: true),
            ),
          ),
        ),
      );
      await flush(tester);
      final retained = tester.state(find.byType(ServerVaultScreen));
      final modal = replacement.startsWith('modal');
      if (!modal) apiA.pendingRead = Completer();
      await tap(tester, 'server-vault-review');
      expect(apiA.reads, 1);
      VoidCallback? confirm;
      if (modal) {
        await tap(tester, 'server-vault-apply');
        confirm = tester
            .widget<CupertinoDialogAction>(
              find.byKey(const ValueKey('server-vault-confirm')),
            )
            .onPressed;
      }
      selected.value = b;
      await flush(tester);
      expect(
        identical(tester.state(find.byType(ServerVaultScreen)), retained),
        isTrue,
      );
      if (!modal) apiA.pendingRead!.complete(apiA.value);
      await flush(tester);
      confirm?.call();
      await flush(tester);
      expect(find.text('Revision 7'), findsNothing);
      expect(find.byKey(const ValueKey('server-vault-apply')), findsNothing);
      expect(storage.writes, isEmpty);
      expect(apiB.reads, 0);
      expect(otherStorage.writes, isEmpty);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      expect(accountA.session, isNotNull);
      selected.value = a;
      await flush(tester);
      expect(find.byKey(const ValueKey('server-vault-review')), findsNothing);
    });
  }
}
