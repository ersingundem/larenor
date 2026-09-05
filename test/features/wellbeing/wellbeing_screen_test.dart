import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/features/wellbeing/domain/wellbeing_models.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_view_privacy.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_disclosure_policy.dart';
import 'package:larenor/features/wellbeing/presentation/wellbeing_gate.dart';
import 'package:larenor/features/wellbeing/presentation/wellbeing_screen.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'wellbeing_controller_test.dart'
    show FakeNative, MemoryStore, Connection;
import 'wellbeing_data_test.dart' show binding;

class _PinStore extends PinLockStore {
  String? pin = '1234';
  Completer<PinAttemptResult>? pending;
  @override
  Future<String?> read() async => pin;
  @override
  Future<PinAttemptResult> verify(String candidate) async => pending == null
      ? PinAttemptResult(accepted: candidate == pin)
      : await pending!.future;
}

class _PrivateStore extends MemoryStore {
  int reads = 0;
  int writes = 0;
  @override
  Future<WellbeingSettings> read() async {
    reads++;
    return super.read();
  }

  @override
  Future<void> save(
    WellbeingSettings value, {
    required bool Function() isCurrent,
  }) async {
    await super.save(value, isCurrent: isCurrent);
    writes++;
  }
}

class _Privacy implements WellbeingViewPrivacyBridge {
  bool fail = false;
  final calls = <bool>[];
  @override
  Future<void> setPrivateView(bool enabled) async {
    calls.add(enabled);
    if (enabled && fail) throw StateError('platform-private-failure');
  }
}

class _Disclosure extends WellbeingDisclosureStore {
  WellbeingDisclosurePolicy policy = WellbeingDisclosurePolicy(
    reviewRequired: true,
    entityIds: {'sensor.private'},
  );
  int writes = 0;
  @override
  Future<WellbeingDisclosurePolicy> read() async => policy;
  @override
  Future<void> save(
    WellbeingDisclosurePolicy value, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const WellbeingException(WellbeingFailure.locked);
    writes++;
    policy = value;
  }
}

Future<void> _mount(
  WidgetTester tester, {
  required _PrivateStore store,
  required FakeNative native,
  _PinStore? pin,
  AppInteractionController? interaction,
  _Privacy? privacy,
  _Disclosure? disclosure,
  bool direct = false,
  bool pushGate = false,
  Size size = const Size(600, 1100),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      wellbeingStoreProvider.overrideWithValue(store),
      wellbeingNativeApiProvider.overrideWithValue(native),
      wellbeingViewPrivacyBridgeProvider.overrideWithValue(
        privacy ?? _Privacy(),
      ),
      if (disclosure != null)
        wellbeingDisclosureStoreProvider.overrideWithValue(disclosure),
      pinLockStoreProvider.overrideWithValue(pin ?? _PinStore()),
      connectionConfigProvider.overrideWith(Connection.new),
      haWellbeingApiProvider.overrideWith((_) => null),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) {
          final scaled = MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          );
          return interaction == null
              ? scaled
              : AppInteractionScope(controller: interaction, child: scaled);
        },
        home: direct
            ? WellbeingScreen(onLock: () {}, onExit: () {})
            : pushGate
            ? Builder(
                builder: (context) => CupertinoPageScaffold(
                  child: Center(
                    child: CupertinoButton(
                      child: const Text('Open private view'),
                      onPressed: () => Navigator.of(context).push(
                        CupertinoPageRoute<void>(
                          builder: (_) => const WellbeingGate(),
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : const WellbeingGate(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (pushGate) {
    await tester.tap(find.text('Open private view'));
    await tester.pumpAndSettle();
  }
}

Future<void> _unlock(WidgetTester tester) async {
  await tester.enterText(find.byKey(const ValueKey('wellbeing-pin')), '1234');
  await tester.ensureVisible(find.text('Unlock'));
  await tester.tap(find.text('Unlock'));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    350,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await Scrollable.ensureVisible(
    tester.element(find.text(text).last),
    alignment: 0.4,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

_PrivateStore _enabled() => _PrivateStore()
  ..settings = WellbeingSettings(
    enabled: true,
    profileLabel: 'Private fixture',
    nativeMetrics: {WellbeingMetric.bodyMass},
    bindings: [binding()],
  );

void main() {
  testWidgets('an unrelated root dialog permanently expires private access', (
    tester,
  ) async {
    await _mount(tester, store: _enabled(), native: FakeNative());
    await _unlock(tester);
    showCupertinoDialog<void>(
      context: tester.element(find.byType(WellbeingGate)),
      builder: (dialog) => CupertinoAlertDialog(
        title: const Text('Root cover'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Close root cover'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WellbeingScreen), findsNothing);
    await tester.tap(find.text('Close root cover'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wellbeing-pin')), findsOneWidget);
    expect(find.byType(WellbeingScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'system back cancels the private child dialog before leaving the page',
    (tester) async {
      await _mount(
        tester,
        store: _enabled(),
        native: FakeNative(),
        pushGate: true,
      );
      await _unlock(tester);
      await _tap(tester, 'Sources');
      await _tap(tester, 'Remove local link');
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(find.byType(WellbeingScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Open private view'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'privacy review is explicit, preserves hiding rules and never reads health',
    (tester) async {
      final policy = _Disclosure();
      final native = FakeNative();
      await _mount(
        tester,
        store: _PrivateStore(),
        native: native,
        disclosure: policy,
      );
      await _unlock(tester);
      expect(policy.writes, 0);
      await _tap(tester, 'Complete privacy review');
      expect(policy.writes, 0);
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'OK'));
      await tester.pumpAndSettle();
      expect(policy.writes, 1);
      expect(policy.policy.reviewRequired, false);
      expect(policy.policy.entityIds, {'sensor.private'});
      expect(native.reads + native.permissions, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('idle expires privacy weakening confirmation', (tester) async {
    final policy = _Disclosure();
    final scope = AppInteractionController();
    addTearDown(scope.dispose);
    await _mount(
      tester,
      store: _PrivateStore(),
      native: FakeNative(),
      disclosure: policy,
      interaction: scope,
    );
    await _unlock(tester);
    await _tap(tester, 'Remove hiding rule');
    final old = tester
        .widget<CupertinoDialogAction>(
          find.widgetWithText(CupertinoDialogAction, 'OK'),
        )
        .onPressed!;
    scope.setActive(false);
    await tester.pump();
    scope.setActive(true);
    await tester.pumpAndSettle();
    old();
    await tester.pumpAndSettle();
    expect(policy.writes, 0);
    expect(policy.policy.entityIds, {'sensor.private'});
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'failed Android private-window protection does not expose health',
    (tester) async {
      final store = _enabled();
      final native = FakeNative();
      final privacy = _Privacy()..fail = true;
      await _mount(tester, store: store, native: native, privacy: privacy);
      await _unlock(tester);
      expect(find.byType(WellbeingScreen), findsNothing);
      expect(find.byKey(const ValueKey('wellbeing-pin')), findsOneWidget);
      expect(store.reads, 0);
      expect(native.probes + native.permissions + native.reads, 0);
      expect(privacy.calls, [true]);
      expect(find.textContaining('platform-private-failure'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'no configured PIN and direct route cannot load private settings',
    (tester) async {
      final store = _enabled();
      final native = FakeNative();
      await _mount(
        tester,
        store: store,
        native: native,
        pin: _PinStore()..pin = null,
      );
      expect(find.text('Open Settings'), findsOneWidget);
      expect(store.reads, 0);
      expect(native.probes + native.reads + native.permissions, 0);
      await tester.pumpWidget(const SizedBox());
      await _mount(tester, store: store, native: native, direct: true);
      expect(store.reads, 0);
      expect(find.text('Private fixture'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final background in [false, true]) {
    testWidgets(
      'late PIN after ${background ? 'background' : 'idle'} cannot unlock',
      (tester) async {
        final scope = AppInteractionController();
        addTearDown(scope.dispose);
        final pin = _PinStore()..pending = Completer();
        final store = _enabled();
        await _mount(
          tester,
          store: store,
          native: FakeNative(),
          pin: pin,
          interaction: scope,
        );
        await tester.enterText(
          find.byKey(const ValueKey('wellbeing-pin')),
          '1234',
        );
        await tester.tap(find.text('Unlock'));
        await tester.pump();
        if (background) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else {
          scope.setActive(false);
          scope.setActive(true);
        }
        pin.pending!.complete(const PinAttemptResult(accepted: true));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('wellbeing-pin')), findsOneWidget);
        expect(store.reads, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'opening and permission grant do not read; explicit read is separate',
    (tester) async {
      final store = _enabled();
      final native = FakeNative();
      await _mount(tester, store: store, native: native);
      await _unlock(tester);
      expect(find.byType(WellbeingScreen), findsOneWidget);
      expect(native.probes + native.permissions + native.reads, 0);
      await _tap(tester, 'Sources');
      await _tap(tester, 'Check available providers');
      expect(native.probes, 1);
      expect(native.reads, 0);
      await _tap(tester, 'Review read permissions');
      expect(native.permissions, 1);
      expect(native.lastMetrics, {WellbeingMetric.bodyMass});
      expect(native.reads, 0);
      await tester.scrollUntilVisible(
        find.text('Readings'),
        -350,
        scrollable: find.byType(Scrollable).first,
      );
      await _tap(tester, 'Readings');
      await _tap(tester, 'Read selected data');
      expect(native.reads, 1);
      expect(store.writes, 0);
      await tester.scrollUntilVisible(
        find.text('No records in the selected period'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('No records in the selected period'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'idle disposes private confirmation and old callback cannot remove binding',
    (tester) async {
      final scope = AppInteractionController();
      addTearDown(scope.dispose);
      final store = _enabled();
      await _mount(
        tester,
        store: store,
        native: FakeNative(),
        interaction: scope,
      );
      await _unlock(tester);
      await _tap(tester, 'Sources');
      await _tap(tester, 'Remove local link');
      final old = tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(CupertinoDialogAction, 'Remove local link'),
          )
          .onPressed!;
      scope.setActive(false);
      await tester.pump();
      scope.setActive(true);
      await tester.pumpAndSettle();
      old();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('wellbeing-pin')), findsOneWidget);
      expect(store.writes, 0);
      expect(store.settings.bindings, hasLength(1));
      expect(find.textContaining('Synthetic person'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('private relock preserves an unrelated root dialog', (
    tester,
  ) async {
    final scope = AppInteractionController();
    addTearDown(scope.dispose);
    await _mount(
      tester,
      store: _enabled(),
      native: FakeNative(),
      interaction: scope,
    );
    await _unlock(tester);
    showCupertinoDialog<void>(
      context: tester.element(find.byType(WellbeingGate)),
      builder: (_) =>
          const CupertinoAlertDialog(title: Text('Unrelated dialog')),
    );
    await tester.pumpAndSettle();
    scope.setActive(false);
    await tester.pump();
    scope.setActive(true);
    await tester.pumpAndSettle();
    expect(find.text('Unrelated dialog'), findsOneWidget);
    expect(find.byType(WellbeingScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [
    const Size(320, 640),
    const Size(1000, 360),
    const Size(1366, 1024),
  ]) {
    testWidgets('private screen scrolls at $size with 200 percent text', (
      tester,
    ) async {
      final native = FakeNative();
      await _mount(
        tester,
        store: _enabled(),
        native: native,
        size: size,
        scale: 2,
      );
      await _unlock(tester);
      await tester.scrollUntilVisible(
        find.text(
          'No readings loaded. Choose sources, review permissions, then read.',
        ),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(native.reads + native.permissions, 0);
      expect(tester.takeException(), isNull);
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await _tap(tester, 'Sources');
      await tester.scrollUntilVisible(
        find.text('Choose a measurement sensor'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose a measurement sensor'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
