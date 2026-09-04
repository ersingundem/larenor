import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
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
