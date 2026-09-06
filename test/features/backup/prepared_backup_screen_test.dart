import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/backup/data/backup_codec.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/backup/presentation/backup_file_access.dart';
import 'package:larenor/features/backup/presentation/backup_screen.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_test_storage.dart';
import 'prepared_restore_test.dart' as f;
import '../home_resources/home_resources_tablet_test.dart' show loadFonts;
import '../../support/restore_dialog_geometry.dart';

class _Codec extends BackupCodec {
  @override
  Future<BackupSnapshot> decrypt(Uint8List bytes, String passphrase) async =>
      f.restoreFixture();
}

class _Files extends BackupFileAccess {
  @override
  Future<Uint8List?> pick() async => Uint8List.fromList([1, 2, 3]);
}

class _Pin extends PinLockStore {
  String? value;
  @override
  Future<String?> read() async => value;
}

class _ScreenHarness {
  final storage = MemoryBackupStorage(preferences: {'appearance': 'dark'});
  final pin = _Pin();
  final boundary = GlobalKey();
  int opens = 0, disposals = 0;
  Future<void> mount(
    WidgetTester tester, {
    String locale = "en",
    double width = 800,
    double height = 1400,
    double scale = 1,
  }) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = Size(width, height);
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
            backupRepositoryProvider.overrideWithValue(
              BackupRepository(storage: storage),
            ),
            backupCodecProvider.overrideWithValue(_Codec()),
            backupFileAccessProvider.overrideWithValue(_Files()),
            pinLockStoreProvider.overrideWithValue(pin),
            windowPolicySnapshotProvider.overrideWith(
              (_) => Stream.value(const WindowPolicySnapshot()),
            ),
          ],
          child: CupertinoApp(
            locale: Locale(locale),
            builder: (context, child) => RepaintBoundary(
              key: boundary,
              child: MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(probe);
                return const BackupScreen(freshInstall: true);
              },
            ),
          ),
        ),
      ),
    );
    await flush(tester);
    await tap(tester, 'backup-pick');
    await tester.enterText(
      find.byKey(const ValueKey('backup-restore-passphrase')),
      'correct backup phrase',
    );
    await tap(tester, 'backup-decrypt');
    await flush(tester);
    final l10n = AppLocalizations.of(tester.element(find.byType(BackupScreen)));
    await reveal(tester, find.text(l10n.backupReplaceSelected));
    await tester.tap(find.text(l10n.backupReplaceSelected));
    await flush(tester);
  }

  Future<void> confirm(WidgetTester tester) async {
    await tap(tester, 'backup-apply');
    await flush(tester);
  }

  Future<void> accept(WidgetTester tester) async {
    await tester.tap(
      find.widgetWithText(CupertinoDialogAction, 'Restore selected content'),
    );
    await flush(tester);
  }
}

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find
          .descendant(
            of: find.byType(BackupScreen),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 30,
    );
  }
  await tester.ensureVisible(finder);
  await flush(tester);
}

Future<void> tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await reveal(tester, finder);
  await tester.tap(finder);
  await flush(tester);
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'Backup effective dialog target and painted label $language $width ${scale}x',
          (tester) async {
            await loadFonts(tester);
            tester.platformDispatcher.platformBrightnessTestValue =
                language == 'tr' ? Brightness.dark : Brightness.light;
            addTearDown(
              tester.platformDispatcher.clearPlatformBrightnessTestValue,
            );
            final semantics = tester.ensureSemantics();
            try {
              final h = _ScreenHarness();
              await h.mount(
                tester,
                locale: language,
                width: width,
                height: 1000,
                scale: scale,
              );
              await h.confirm(tester);
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
              await focusRestoreCancel(tester, cancel, flush);
              if ((language == 'en' &&
                      (width == 600 && scale == 1 ||
                          width == 1280 && scale == 2)) ||
                  (language == 'tr' && width == 600 && scale == 2)) {
                await captureRestoreDialog(
                  tester,
                  h.boundary,
                  'backup-$language-${width.toInt()}-${scale.toInt()}x',
                );
              }
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await flush(tester);
              expect(find.byType(CupertinoAlertDialog), findsNothing);
              expect(h.storage.writes, isEmpty);
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

  testWidgets(
    'actual BackupScreen hands off typed v2 intent and mounts fresh providers',
    (tester) async {
      final h = _ScreenHarness();
      await h.mount(tester);
      await h.confirm(tester);
      await h.accept(tester);
      expect(h.storage.preferences['appearance'], 'light');
      expect(h.disposals, 1);
      expect(h.opens, 2);
      expect(h.storage.writes, contains('secret:backup_restore_journal_v2'));
      expect(
        h.storage.writes,
        isNot(contains('secret:${BackupRepository.restoreJournalKey}')),
      );
      expect(h.storage.secrets, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'target changed under retained confirmation has zero writes and no runtime disposal',
    (tester) async {
      final h = _ScreenHarness();
      await h.mount(tester);
      await h.confirm(tester);
      h.storage.preferences['appearance'] = 'system';
      await h.accept(tester);
      expect(h.storage.preferences['appearance'], 'system');
      expect(h.storage.writes, isEmpty);
    },
  );
  testWidgets(
    'persisted source changed under retained approval cannot retarget Direct restore',
    (tester) async {
      final h = _ScreenHarness();
      await h.mount(tester);
      await h.confirm(tester);
      await SharedPreferencesHomeSourceStore().write(HomeSource.verifiedCore);
      await h.accept(tester);
      expect(h.storage.preferences['appearance'], 'dark');
      expect(h.storage.writes, isEmpty);
      expect(h.disposals, 0);
    },
  );
  for (final event in [
    'inactive',
    'nativeFocus',
    'pinLoading',
    'pinStore',
    'opaqueRoute',
  ]) {
    testWidgets(
      'retained confirmation cannot survive $event retirement and return',
      (tester) async {
        final h = _ScreenHarness();
        await h.mount(tester);
        await h.confirm(tester);
        final screenContext = tester.element(find.byType(BackupScreen));
        final old = tester
            .widget<CupertinoDialogAction>(
              find.widgetWithText(
                CupertinoDialogAction,
                'Restore selected content',
              ),
            )
            .onPressed!;
        if (event == 'inactive') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else if (event == 'nativeFocus') {
          tester.binding.handleViewFocusChanged(
            ViewFocusEvent(
              viewId: tester.view.viewId,
              state: ViewFocusState.unfocused,
              direction: ViewFocusDirection.undefined,
            ),
          );
          tester.binding.handleViewFocusChanged(
            ViewFocusEvent(
              viewId: tester.view.viewId,
              state: ViewFocusState.focused,
              direction: ViewFocusDirection.undefined,
            ),
          );
        } else if (event == 'pinLoading') {
          ProviderScope.containerOf(
            screenContext,
            listen: false,
          ).invalidate(pinLockProvider);
        } else if (event == 'pinStore') {
          h.pin.value = '1234';
        } else {
          final navigator = Navigator.of(screenContext);
          navigator.push(
            CupertinoPageRoute<void>(
              builder: (_) =>
                  const CupertinoPageScaffold(child: Text('Covered route')),
            ),
          );
          await flush(tester);
          navigator.pop();
          await flush(tester);
        }
        old();
        await flush(tester);
        expect(h.storage.writes, isEmpty);
        expect(h.disposals, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'final confirmation renders the newly prepared target summary and frozen conflict',
    (tester) async {
      final h = _ScreenHarness();
      await h.mount(tester);
      h.storage.preferences.remove('appearance');
      await h.confirm(tester);
      final dialog = find.byType(CupertinoAlertDialog);
      expect(
        find.descendant(of: dialog, matching: find.text('0 preferences')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('Replace selected')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Destination: this device.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('From backup')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Existing data on this device'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.textContaining('rooms')),
        findsNothing,
      );
      expect(h.storage.writes, isEmpty);
    },
  );

  testWidgets(
    'confirmation keyboard Tab and Enter can cancel without restoring',
    (tester) async {
      final h = _ScreenHarness();
      await h.mount(tester);
      await h.confirm(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await flush(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await flush(tester);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(h.storage.writes, isEmpty);
    },
  );

  for (final locale in ['en', 'tr']) {
    for (final width in [320.0, 600.0, 1280.0]) {
      testWidgets('prepared confirmation real fonts $locale $width at 2x', (
        tester,
      ) async {
        await loadFonts(tester);
        final semantics = tester.ensureSemantics();
        try {
          final h = _ScreenHarness();
          await h.mount(
            tester,
            locale: locale,
            width: width,
            height: 1000,
            scale: 2,
          );
          await h.confirm(tester);
          final dialog = find.byType(CupertinoAlertDialog);
          final l10n = AppLocalizations.of(tester.element(dialog));
          final cancel = find.widgetWithText(
            CupertinoDialogAction,
            l10n.commonCancel,
          );
          final accept = find.widgetWithText(
            CupertinoDialogAction,
            l10n.backupApply,
          );
          for (final finder in [cancel, accept]) {
            await tester.ensureVisible(finder);
            await flush(tester);
            expect(tester.getRect(finder).height, greaterThanOrEqualTo(48));
            final node = tester.getSemantics(finder);
            expect(node.flagsCollection.isButton, isTrue);
            expect(node.label, isNotEmpty);
          }
          expect(
            find.descendant(
              of: dialog,
              matching: find.text(l10n.backupRestoreTargetDevice),
            ),
            findsOneWidget,
          );
          expect(h.storage.writes, isEmpty);
          expect(tester.takeException(), isNull);
          const directory = String.fromEnvironment('RESTORE_PREVIEW_DIR');
          if (directory.isNotEmpty) {
            await tester.runAsync(() async {
              await Directory(directory).create(recursive: true);
              final render =
                  h.boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary;
              final image = await render.toImage(pixelRatio: 1);
              try {
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File('$directory/restore-$locale-${width.toInt()}-2x.png')
                    .writeAsBytes(data!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }
          await tester.tap(cancel);
          await flush(tester);
          expect(find.byType(CupertinoAlertDialog), findsNothing);
          expect(h.storage.writes, isEmpty);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
