import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PendingStore extends PinLockStore {
  final completion = Completer<PinAttemptResult>();
  @override
  Future<String?> read() async => '1234';
  @override
  Future<PinAttemptResult> verify(String candidate) => completion.future;
}

Future<void> showGate(
  WidgetTester tester, {
  PinLockStore? store,
  String? initialPin = '1234',
  bool pushGate = false,
  AppInteractionController? interaction,
}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({'settings_pin': ?initialPin});
  tester.view.physicalSize = const Size(500, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (store != null) pinLockStoreProvider.overrideWith((ref) => store),
      ],
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (_, child) => interaction == null
            ? child!
            : AppInteractionScope(controller: interaction, child: child!),
        home: pushGate
            ? Builder(
                builder: (context) => CupertinoPageScaffold(
                  child: CupertinoButton(
                    child: const Text('Open settings'),
                    onPressed: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => const SettingsGateScreen(),
                      ),
                    ),
                  ),
                ),
              )
            : const SettingsGateScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (pushGate) {
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
  }
}

class PendingSaveStore extends PinLockStore {
  final completion = Completer<void>();
  @override
  Future<void> save(String pin) async {
    await completion.future;
    await super.save(pin);
  }
}

void main() {
  testWidgets(
    'owned settings navigator preserves pane back and app back navigation',
    (tester) async {
      await showGate(tester, initialPin: null, pushGate: true);
      await tester.tap(find.text('Display & Brightness'));
      await tester.pumpAndSettle();
      expect(find.text('Keep screen on'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Security'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Open settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'idle clears an uncommitted first PIN even when no PIN was configured',
    (tester) async {
      final scope = AppInteractionController();
      addTearDown(scope.dispose);
      await showGate(tester, initialPin: null, interaction: scope);
      await tester.tap(find.text('Security'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set PIN'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField), '9876');
      final old = tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(CupertinoDialogAction, 'Save'),
          )
          .onPressed!;
      scope.setActive(false);
      await tester.pump();
      scope.setActive(true);
      await tester.pumpAndSettle();
      old();
      await tester.pumpAndSettle();
      expect(await PinLockStore().read(), isNull);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'idle relocks settings and expires an old PIN-save dialog without changing PIN',
    (tester) async {
      final scope = AppInteractionController();
      addTearDown(scope.dispose);
      await showGate(tester, interaction: scope, pushGate: true);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Security'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change PIN'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField), '9876');
      final old = tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(CupertinoDialogAction, 'Save'),
          )
          .onPressed!;
      scope.setActive(false);
      await tester.pump();
      scope.setActive(true);
      await tester.pumpAndSettle();
      old();
      await tester.pumpAndSettle();
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.text('Open settings'), findsNothing);
      expect(await PinLockStore().read(), '1234');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'idle keeps an unrelated root dialog while clearing owned settings routes',
    (tester) async {
      final scope = AppInteractionController();
      addTearDown(scope.dispose);
      await showGate(tester, interaction: scope, pushGate: true);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Display & Brightness'));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(SettingsGateScreen));
      showCupertinoDialog<void>(
        context: context,
        builder: (dialog) => CupertinoAlertDialog(
          title: const Text('Unrelated root dialog'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Close unrelated'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      scope.setActive(false);
      await tester.pump();
      scope.setActive(true);
      await tester.pumpAndSettle();
      expect(find.text('Unrelated root dialog'), findsOneWidget);
      await tester.tap(find.text('Close unrelated'));
      await tester.pumpAndSettle();
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.text('Keep screen on'), findsNothing);
      expect(find.text('Open settings'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('verification begun before idle cannot unlock after wake', (
    tester,
  ) async {
    final scope = AppInteractionController();
    addTearDown(scope.dispose);
    final store = PendingStore();
    await showGate(tester, store: store, interaction: scope);
    await tester.enterText(find.byType(CupertinoTextField), '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pump();
    scope.setActive(false);
    await tester.pump();
    scope.setActive(true);
    await tester.pump();
    store.completion.complete(const PinAttemptResult(accepted: true));
    await tester.pumpAndSettle();
    expect(find.text('Unlock'), findsOneWidget);
    expect(find.text('Security'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'first PIN creation closes a pane opened without authentication',
    (tester) async {
      await showGate(tester, initialPin: null);
      await tester.tap(find.text('Security'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set PIN'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField), '9876');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.text('Remove PIN'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a PIN save completing during dialog dismissal cannot pop the gate',
    (tester) async {
      final store = PendingSaveStore();
      await showGate(tester, store: store, pushGate: true);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Security'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change PIN'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField), '9876');
      await tester.tap(find.text('Save'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      store.completion.complete();
      await tester.pump();
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.text('Open settings'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('backgrounding relocks settings and removes pushed phone panes', (
    tester,
  ) async {
    await showGate(tester);
    await tester.enterText(find.byType(CupertinoTextField), '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Display & Brightness'));
    await tester.pumpAndSettle();
    expect(find.text('Keep screen on'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Unlock'), findsOneWidget);
    expect(find.text('Keep screen on'), findsNothing);
    expect(
      tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('verification completing in background cannot unlock on return', (
    tester,
  ) async {
    final store = PendingStore();
    await showGate(tester, store: store);
    await tester.enterText(find.byType(CupertinoTextField), '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    store.completion.complete(const PinAttemptResult(accepted: true));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Unlock'), findsOneWidget);
    expect(find.text('Display & Brightness'), findsNothing);
  });
}
