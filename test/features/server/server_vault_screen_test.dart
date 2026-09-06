import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/presentation/backup_screen.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/presentation/server_vault_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/backup_test_storage.dart';
import 'server_vault_test_support.dart';

void main() {
  late VaultApi api;
  late ServerAccountController account;
  late MemoryBackupStorage storage;
  late GlobalKey<NavigatorState> navigation;
  Future<void> Function()? restoreOperation;
  int restoreHandoffs = 0;

  setUp(() {
    api = VaultApi();
    storage = MemoryBackupStorage(
      preferences: {'appearance': 'light'},
      secrets: {
        'settings_pin': 'fixture-pin',
        'ha_base_url': 'https://local-private.invalid',
        'ha_token': 'synthetic_local_secret',
      },
    );
    navigation = GlobalKey<NavigatorState>();
    restoreOperation = null;
    restoreHandoffs = 0;
  });

  Future<void> mount(
    WidgetTester tester, {
    bool fresh = false,
    String? pin,
    double width = 600,
    double scale = 1,
    String language = 'en',
    AppInteractionController? interaction,
    ValueNotifier<bool>? visible,
  }) async {
    account = ServerAccountController(
      store: VaultAccountStore(),
      apiFactory: (_) => api,
    );
    await account.initialize();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': ?pin});
    tester.view.physicalSize = Size(width, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final screen = ServerVaultScreen(freshInstall: fresh);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(account),
          backupRepositoryProvider.overrideWithValue(
            BackupRepository(storage: storage),
          ),
          preparedBackupRestoreHandlerProvider.overrideWithValue((
            context,
            prepared,
            l10n,
          ) async {
            restoreHandoffs++;
            final owner = Object();
            await prepared.checkBeforeHandoff();
            prepared.claimForHandoff(owner);
            restoreOperation = () => prepared.applyAfterHandoff(
              owner,
              isCurrentBoundary: () => true,
            );
          }),
        ],
        child: CupertinoApp(
          navigatorKey: navigation,
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: interaction == null
                ? child!
                : AppInteractionScope(controller: interaction, child: child!),
          ),
          home: visible == null
              ? screen
              : ValueListenableBuilder<bool>(
                  valueListenable: visible,
                  builder: (_, value, child) =>
                      TickerMode(enabled: value, child: child!),
                  child: screen,
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      account.dispose();
    });
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> background(WidgetTester tester) async {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
  }

  Future<void> resume(WidgetTester tester) async {
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  void expectNoSecrets(WidgetTester tester) {
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .join('\n');
    for (final secret in [
      'synthetic_private_ha_secret',
      'private-fixture.invalid',
      'secret_fixture_user',
      'synthetic_proxmox_secret',
      'synthetic_access',
      'sensor.private_fixture',
    ]) {
      expect(text, isNot(contains(secret)));
    }
  }

  testWidgets(
    'entry is passive; review is read-only with no displayed secret values',
    (tester) async {
      await mount(tester);
      expect(api.reads, 0);
      expect(
        tester
            .widget<CupertinoSwitch>(
              find.byKey(const ValueKey('server-vault-connections')),
            )
            .value,
        isFalse,
      );
      await tap(tester, 'server-vault-review');
      expect(api.reads, 1);
      expect(api.writes, 0);
      expect(storage.writes, isEmpty);
      expect(find.text('Revision 7'), findsOneWidget);
      expect(find.textContaining('ha, proxmox'), findsOneWidget);
      expectNoSecrets(tester);
    },
  );

  testWidgets('upload cancel and duplicate modal callback never send a PUT', (
    tester,
  ) async {
    await mount(tester);
    await tap(tester, 'server-vault-upload-mode');
    await tap(tester, 'server-vault-review');
    final button = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('server-vault-apply')),
        )
        .onPressed!;
    button();
    button();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    final oldConfirm = tester
        .widget<CupertinoDialogAction>(
          find.byKey(const ValueKey('server-vault-confirm')),
        )
        .onPressed!;
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
    await tester.pumpAndSettle();
    oldConfirm();
    await tester.pumpAndSettle();
    expect(api.writes, 0);
    expect(storage.writes, isEmpty);
    expect(find.text('Revision 7'), findsNothing);
  });

  testWidgets(
    'explicit upload sends one selected document with reviewed revision',
    (tester) async {
      await mount(tester);
      await tap(tester, 'server-vault-upload-mode');
      await tap(tester, 'server-vault-review');
      await tap(tester, 'server-vault-apply');
      final confirm = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('server-vault-confirm')),
          )
          .onPressed!;
      confirm();
      confirm();
      await tester.pumpAndSettle();
      expect(api.writes, 1);
      expect(api.expectedRevision, 7);
      expect(
        jsonEncode(api.uploaded!.toJson()),
        isNot(contains('synthetic_local_secret')),
      );
      expect(storage.writes, isEmpty);
      expect(
        find.text('The server confirmed that the vault was saved.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'revision conflict requires a new review and never silently retries',
    (tester) async {
      await mount(tester);
      await tap(tester, 'server-vault-upload-mode');
      await tap(tester, 'server-vault-review');
      api.writeError = 'revision_conflict';
      await tap(tester, 'server-vault-apply');
      await tap(tester, 'server-vault-confirm');
      await tester.pumpAndSettle();
      expect(api.writes, 1);
      expect(find.textContaining('The server vault changed.'), findsOneWidget);
      expect(find.byKey(const ValueKey('server-vault-apply')), findsNothing);
      expect(storage.writes, isEmpty);
    },
  );

  testWidgets(
    'restore reviews privacy/certificate then hands local operation to reset boundary',
    (tester) async {
      await mount(tester, fresh: true);
      await tap(tester, 'server-vault-connections');
      await tap(tester, 'server-vault-replace');
      await tap(tester, 'server-vault-review');
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ServerVaultScreen)),
      );
      expect(find.text(l10n.backupCertificateReview), findsOneWidget);
      expect(find.text(l10n.backupPrivacyReviewRequired), findsOneWidget);
      await tap(tester, 'server-vault-apply');
      await tap(tester, 'server-vault-confirm');
      expect(restoreHandoffs, 1);
      expect(api.reads, 2);
      expect(api.writes, 0);
      expect(storage.writes, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await restoreOperation!();
      expect(storage.preferences['appearance'], 'dark');
      expect(storage.secrets['ha_token'], 'synthetic_private_ha_secret');
      expect(storage.secrets['settings_pin'], 'fixture-pin');
      expect(storage.secrets['proxmox_allow_self_signed'], 'false');
    },
  );

  testWidgets(
    'read failure differs from an empty vault and exposes no raw error',
    (tester) async {
      await mount(tester);
      api.readError = 'synthetic_private_ha_secret';
      await tap(tester, 'server-vault-review');
      expect(
        find.textContaining('could not be read or validated'),
        findsOneWidget,
      );
      expect(
        find.text('There is no saved vault on this server account.'),
        findsNothing,
      );
      expectNoSecrets(tester);
      expect(storage.writes, isEmpty);
    },
  );

  testWidgets('fresh install with existing PIN cannot load the vault', (
    tester,
  ) async {
    await mount(tester, fresh: true, pin: '123456');
    expect(find.byKey(const ValueKey('server-vault-review')), findsNothing);
    expect(api.reads, 0);
    expect(storage.reads, isEmpty);
  });

  testWidgets(
    'PIN change cancels a pending read and keeps the old route locked',
    (tester) async {
      await mount(tester, pin: '123456');
      api.pendingRead = Completer();
      await tap(tester, 'server-vault-review');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ServerVaultScreen)),
      );
      FlutterSecureStorage.setMockInitialValues({'settings_pin': '654321'});
      container.invalidate(pinLockProvider);
      await tester.pump();
      api.pendingRead!.complete(api.value);
      await tester.pumpAndSettle();
      expect(find.text('Revision 7'), findsNothing);
      expect(find.byKey(const ValueKey('server-vault-review')), findsNothing);
      expect(storage.writes, isEmpty);
    },
  );

  testWidgets(
    'account switch while reading cannot expose old vault or local restore',
    (tester) async {
      await mount(tester);
      api.pendingRead = Completer();
      await tap(tester, 'server-vault-review');
      await account.signOut();
      api.pendingRead!.complete(api.value);
      await tester.pumpAndSettle();
      expect(find.text('Revision 7'), findsNothing);
      expect(find.byKey(const ValueKey('server-vault-review')), findsNothing);
      expect(storage.writes, isEmpty);
    },
  );

  testWidgets(
    'background discards owned confirmation and old button stays inert',
    (tester) async {
      await mount(tester);
      await tap(tester, 'server-vault-upload-mode');
      await tap(tester, 'server-vault-review');
      await tap(tester, 'server-vault-apply');
      final confirm = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('server-vault-confirm')),
          )
          .onPressed!;
      await background(tester);
      await resume(tester);
      confirm();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(find.text('Revision 7'), findsNothing);
      expect(api.writes, 0);
    },
  );

  testWidgets(
    'idle expiry removes only owned dialog and does not reactivate old confirmation',
    (tester) async {
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await mount(tester, interaction: interaction);
      await tap(tester, 'server-vault-upload-mode');
      await tap(tester, 'server-vault-review');
      await tap(tester, 'server-vault-apply');
      final confirm = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('server-vault-confirm')),
          )
          .onPressed!;
      interaction.setActive(false);
      await tester.pump();
      interaction.setActive(true);
      await tester.pumpAndSettle();
      confirm();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(find.text('Revision 7'), findsNothing);
      expect(api.writes, 0);
    },
  );

  testWidgets('hidden route discards delayed read without a local write', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await mount(tester, visible: visible);
    api.pendingRead = Completer();
    await tap(tester, 'server-vault-review');
    visible.value = false;
    await tester.pump();
    api.pendingRead!.complete(api.value);
    await tester.pump();
    visible.value = true;
    await tester.pumpAndSettle();
    expect(find.text('Revision 7'), findsNothing);
    expect(storage.writes, isEmpty);
    expect(api.writes, 0);
  });

  testWidgets(
    'unrelated nonopaque route cover removes review without closing that route',
    (tester) async {
      await mount(tester);
      await tap(tester, 'server-vault-review');
      final covered = navigation.currentState!.push<void>(
        PageRouteBuilder(
          opaque: false,
          pageBuilder: (_, _, _) =>
              const Center(child: Text('Independent cover')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Independent cover'), findsOneWidget);
      expect(find.text('Revision 7'), findsNothing);
      navigation.currentState!.pop();
      await covered;
      await tester.pumpAndSettle();
      expect(find.text('Revision 7'), findsNothing);
      expect(api.writes, 0);
    },
  );

  testWidgets(
    'covering an owned confirmation expires it and preserves the independent route',
    (tester) async {
      await mount(tester);
      await tap(tester, 'server-vault-upload-mode');
      await tap(tester, 'server-vault-review');
      await tap(tester, 'server-vault-apply');
      final confirm = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('server-vault-confirm')),
          )
          .onPressed!;
      final covered = navigation.currentState!.push<void>(
        PageRouteBuilder(
          opaque: false,
          pageBuilder: (_, _, _) =>
              const Center(child: Text('Independent cover')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Independent cover'), findsOneWidget);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      navigation.currentState!.pop();
      await covered;
      await tester.pumpAndSettle();
      confirm();
      await tester.pumpAndSettle();
      expect(api.writes, 0);
      expect(storage.writes, isEmpty);
      expect(find.text('Revision 7'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hiding an owned confirmation discards it outside the build phase',
    (tester) async {
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await mount(tester, visible: visible);
      await tap(tester, 'server-vault-upload-mode');
      await tap(tester, 'server-vault-review');
      await tap(tester, 'server-vault-apply');
      final confirm = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('server-vault-confirm')),
          )
          .onPressed!;
      visible.value = false;
      await tester.pump();
      visible.value = true;
      await tester.pumpAndSettle();
      confirm();
      await tester.pumpAndSettle();
      expect(api.writes, 0);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final dimensions in [(320.0, 2.0), (1280.0, 1.6)]) {
    testWidgets(
      'review and controls fit ${dimensions.$1}px at ${dimensions.$2}x',
      (tester) async {
        await mount(
          tester,
          width: dimensions.$1,
          scale: dimensions.$2,
          language: 'tr',
        );
        await tap(tester, 'server-vault-review');
        await tap(tester, 'server-vault-apply');
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        expectNoSecrets(tester);
      },
    );
  }
}
