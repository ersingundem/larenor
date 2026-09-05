import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/kiosk/data/kiosk_api.dart';
import 'package:larenor/features/kiosk/domain/kiosk_models.dart';
import 'package:larenor/features/kiosk/presentation/kiosk_screen.dart';
import 'package:larenor/features/kiosk/providers/kiosk_providers.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Pin extends PinLockStore {
  String? value = '1234';
  int checks = 0;
  Completer<void>? pending;
  @override
  Future<String?> read() async => value;
  @override
  Future<PinAttemptResult> verify(String pin) async {
    checks++;
    await pending?.future;
    return PinAttemptResult(accepted: pin == value);
  }
}

class _Api extends KioskApi {
  int reads = 0, proposals = 0, writes = 0, cancels = 0;
  Completer<void>? reading, preparing, writing;
  bool failRead = false;
  KioskOutcome outcome = KioskOutcome.observed;
  KioskSnapshot current = KioskSnapshot(
    supported: true,
    deviceOwner: true,
    permitted: true,
    lockState: KioskLockState.none,
    resumed: true,
    focused: true,
    eligibleWindow: true,
    keyguardLocked: false,
    powerMenuAllowed: true,
    actions: {KioskAction.enter, KioskAction.removeApp},
  );
  @override
  Future<KioskSnapshot> snapshot() async {
    reads++;
    await reading?.future;
    if (failRead) throw StateError('private device detail');
    return current;
  }

  @override
  Future<KioskIntent> prepare(KioskAction action) async {
    proposals++;
    await preparing?.future;
    return KioskIntent(
      id: 'one-use-000000000000000',
      action: action,
      snapshot: current,
    );
  }

  @override
  Future<KioskReceipt> execute(KioskIntent intent) async {
    writes++;
    await writing?.future;
    if (outcome == KioskOutcome.observed) {
      current = KioskSnapshot(
        supported: true,
        deviceOwner: true,
        permitted: true,
        lockState: KioskLockState.locked,
        resumed: true,
        focused: true,
        eligibleWindow: true,
        keyguardLocked: false,
        powerMenuAllowed: true,
        actions: {KioskAction.exit, KioskAction.removeApp},
      );
    }
    return KioskReceipt(outcome, current);
  }

  @override
  Future<void> cancel(KioskIntent intent) async {
    cancels++;
  }
}

Future<void> _mount(
  WidgetTester t,
  _Api api,
  _Pin pin, {
  AppInteractionController? interaction,
  ValueNotifier<bool>? visibility,
  Size size = const Size(600, 1000),
  double scale = 1,
}) async {
  final active = interaction ?? AppInteractionController();
  if (interaction == null) addTearDown(active.dispose);
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        kioskApiProvider.overrideWithValue(api),
        pinLockStoreProvider.overrideWithValue(pin),
      ],
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) {
          final content = AppInteractionScope(
            controller: active,
            child: MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
          );
          return visibility == null
              ? content
              : ValueListenableBuilder<bool>(
                  valueListenable: visibility,
                  builder: (_, enabled, _) =>
                      TickerMode(enabled: enabled, child: content),
                );
        },
        home: const KioskScreen(),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pumpAndSettle();
}

Future<void> confirm(WidgetTester t, {String pin = '1234'}) async {
  await t.enterText(find.byKey(const ValueKey('kiosk-pin')), pin);
  await tap(t, 'kiosk-confirm');
}

void main() {
  testWidgets(
    'opening shows observed status with zero policy writes and recovery available',
    (t) async {
      final api = _Api();
      await _mount(t, api, _Pin());
      expect(api.reads, 1);
      expect(api.proposals, 0);
      expect(api.writes, 0);
      expect(find.text('No lock task'), findsOneWidget);
      expect(find.text('Recovery and device setup'), findsOneWidget);
    },
  );
  testWidgets('not allowlisted disables enter and never opens screen pinning', (
    t,
  ) async {
    final api = _Api()
      ..current = KioskSnapshot(
        supported: true,
        deviceOwner: false,
        permitted: false,
        lockState: KioskLockState.none,
      );
    await _mount(t, api, _Pin());
    expect(
      t
          .widget<CupertinoButton>(find.byKey(const ValueKey('kiosk-enter')))
          .onPressed,
      isNull,
    );
    expect(api.proposals, 0);
  });
  testWidgets('screen pinning is visibly distinct from managed lock', (
    t,
  ) async {
    final api = _Api()
      ..current = KioskSnapshot(
        supported: true,
        lockState: KioskLockState.pinned,
        actions: {KioskAction.exit},
      );
    await _mount(t, api, _Pin());
    expect(find.text('Screen pinning · user-removable'), findsOneWidget);
    expect(find.text('Managed lock task'), findsNothing);
  });
  testWidgets('missing PIN blocks proposal and explains prerequisite', (
    t,
  ) async {
    final api = _Api();
    await _mount(t, api, _Pin()..value = null);
    await tap(t, 'kiosk-enter');
    expect(api.proposals, 0);
    expect(api.writes, 0);
    expect(find.textContaining('Set a Settings PIN'), findsOneWidget);
  });
  testWidgets('cancel after named action performs zero policy writes', (
    t,
  ) async {
    final api = _Api();
    await _mount(t, api, _Pin());
    await tap(t, 'kiosk-enter');
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(api.writes, 0);
    await t.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
    await t.pumpAndSettle();
    expect(api.writes, 0);
    expect(api.cancels, greaterThan(0));
  });
  testWidgets(
    'fresh PIN confirm writes exactly once and displays actual observed state',
    (t) async {
      final api = _Api(), pin = _Pin();
      await _mount(t, api, pin);
      await tap(t, 'kiosk-enter');
      await confirm(t);
      expect(pin.checks, 1);
      expect(api.writes, 1);
      expect(find.text('Managed lock task'), findsOneWidget);
      expect(
        find.textContaining('requested state was observed'),
        findsOneWidget,
      );
    },
  );
  testWidgets('wrong PIN never invokes native execution', (t) async {
    final api = _Api();
    await _mount(t, api, _Pin());
    await tap(t, 'kiosk-enter');
    await confirm(t, pin: '9999');
    expect(api.writes, 0);
    expect(find.text('Incorrect PIN'), findsOneWidget);
  });
  testWidgets(
    'double action and old confirm callback cannot duplicate a native command',
    (t) async {
      final api = _Api();
      await _mount(t, api, _Pin());
      final start = t
          .widget<CupertinoButton>(find.byKey(const ValueKey('kiosk-enter')))
          .onPressed!;
      start();
      start();
      await t.pumpAndSettle();
      expect(api.proposals, 1);
      await t.enterText(find.byKey(const ValueKey('kiosk-pin')), '1234');
      final old = t
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('kiosk-confirm')),
          )
          .onPressed!;
      old();
      old();
      await t.pumpAndSettle();
      expect(api.writes, 1);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'idle closes PIN dialog and old confirmation remains invalid after wake',
    (t) async {
      final api = _Api(), active = AppInteractionController();
      addTearDown(active.dispose);
      await _mount(t, api, _Pin(), interaction: active);
      await tap(t, 'kiosk-enter');
      await t.enterText(find.byKey(const ValueKey('kiosk-pin')), '1234');
      final old = t
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('kiosk-confirm')),
          )
          .onPressed!;
      active.setActive(false);
      await t.pumpAndSettle();
      active.setActive(true);
      await t.pumpAndSettle();
      old();
      await t.pumpAndSettle();
      expect(api.writes, 0);
      expect(find.byKey(const ValueKey('kiosk-pin')), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'PIN verification completing after background cannot issue a write',
    (t) async {
      final api = _Api(), pin = _Pin()..pending = Completer<void>();
      await _mount(t, api, pin);
      await tap(t, 'kiosk-enter');
      await t.enterText(find.byKey(const ValueKey('kiosk-pin')), '1234');
      await t.tap(find.byKey(const ValueKey('kiosk-confirm')));
      await t.pump(const Duration(milliseconds: 400));
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await t.pump();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      pin.pending!.complete();
      await t.pumpAndSettle();
      expect(api.writes, 0);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'hidden entire window expires pending PIN instead of reviving it on return',
    (t) async {
      final api = _Api(), visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await _mount(t, api, _Pin(), visibility: visible);
      await tap(t, 'kiosk-enter');
      await t.enterText(find.byKey(const ValueKey('kiosk-pin')), '1234');
      final old = t
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('kiosk-confirm')),
          )
          .onPressed!;
      visible.value = false;
      await t.pumpAndSettle();
      visible.value = true;
      await t.pumpAndSettle();
      old();
      await t.pumpAndSettle();
      expect(api.writes, 0);
      expect(find.byKey(const ValueKey('kiosk-pin')), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'unmount with an owned PIN popup cancels without stale native write',
    (t) async {
      final api = _Api();
      await _mount(t, api, _Pin());
      await tap(t, 'kiosk-enter');
      final old = t
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('kiosk-confirm')),
          )
          .onPressed!;
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
      old();
      await t.pumpAndSettle();
      expect(api.writes, 0);
      expect(t.takeException(), isNull);
    },
  );
  for (final outcome in [KioskOutcome.accepted, KioskOutcome.unknown]) {
    testWidgets(
      '$outcome never masquerades as observed or automatically retries',
      (t) async {
        final api = _Api()..outcome = outcome;
        await _mount(t, api, _Pin());
        await tap(t, 'kiosk-enter');
        await confirm(t);
        expect(api.writes, 1);
        expect(
          find.textContaining('requested state was observed'),
          findsNothing,
        );
        expect(
          t
              .widget<CupertinoButton>(
                find.byKey(const ValueKey('kiosk-enter')),
              )
              .onPressed,
          isNull,
        );
        await tap(t, 'kiosk-refresh');
        expect(api.writes, 1);
        expect(api.reads, 2);
      },
    );
  }
  testWidgets('failed refresh hides stale managed state and raw errors', (
    t,
  ) async {
    final api = _Api();
    await _mount(t, api, _Pin());
    await tap(t, 'kiosk-enter');
    await confirm(t);
    expect(find.text('Managed lock task'), findsOneWidget);
    api.failRead = true;
    await tap(t, 'kiosk-refresh');
    expect(find.text('Managed lock task'), findsNothing);
    expect(find.textContaining('private device'), findsNothing);
    expect(find.text('Recovery and device setup'), findsOneWidget);
  });
  for (final size in [const Size(320, 640), const Size(1366, 1024)]) {
    testWidgets(
      'grouped kiosk controls and confirmation fit $size at 200% text',
      (t) async {
        final api = _Api();
        await _mount(t, api, _Pin(), size: size, scale: 2);
        expect(t.takeException(), isNull);
        await tap(t, 'kiosk-enter');
        expect(t.takeException(), isNull);
        await confirm(t);
        expect(api.writes, 1);
        expect(t.takeException(), isNull);
      },
    );
  }
}
