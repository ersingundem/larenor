import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/settings/presentation/window_panel_screen.dart';
import 'package:larenor/features/settings/providers/window_profile_provider.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

class _Store implements WindowProfileStore {
  String value = 'adaptive';
  int writes = 0;
  bool fail = false;
  @override
  Future<Object?> read() async => value;
  @override
  Future<void> write(WindowProfile profile) async {
    writes++;
    if (fail) throw StateError('private storage failure');
    value = profile.name;
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Store store,
  WindowPolicySnapshot snapshot, {
  Size size = const Size(600, 1100),
  double scale = 1,
  Locale locale = const Locale('tr'),
  bool snapshotError = false,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        windowProfileStoreProvider.overrideWithValue(store),
        windowPolicySnapshotProvider.overrideWith(
          (_) => snapshotError
              ? Stream.error(StateError('private platform detail'))
              : Stream.value(snapshot),
        ),
      ],
      child: CupertinoApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const WindowPanelScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('read-only opening does not change mode; unknown is not false', (
    tester,
  ) async {
    final store = _Store();
    await _mount(tester, store, const WindowPolicySnapshot());
    expect(store.writes, 0);
    expect(find.text('Hayır'), findsNothing);
    expect(find.text('Bilinmiyor'), findsWidgets);
    final panel = find.widgetWithText(CupertinoButton, 'Duvar paneli');
    expect(tester.widget<CupertinoButton>(panel).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit profile save does not claim native bars were hidden', (
    tester,
  ) async {
    final store = _Store();
    await _mount(
      tester,
      store,
      const WindowPolicySnapshot(
        supported: true,
        effectiveMode: WindowEffectiveMode.restricted,
        reason: WindowRestrictionReason.multiWindow,
        isMultiWindow: true,
        statusBarVisible: true,
        navigationBarVisible: true,
      ),
    );
    await tester.tap(find.text('Duvar paneli'));
    await tester.pumpAndSettle();
    expect(store.writes, 1);
    expect(store.value, 'panel');
    expect(find.text('Sistem kontrolleri korunuyor'), findsOneWidget);
    expect(find.text('Panel görünümü istendi'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save failure keeps choice and shows a safe error', (
    tester,
  ) async {
    final store = _Store()..fail = true;
    await _mount(tester, store, const WindowPolicySnapshot(supported: true));
    await tester.tap(find.text('Duvar paneli'));
    await tester.pumpAndSettle();
    expect(store.value, 'adaptive');
    expect(find.textContaining('Görünüm modu kaydedilemedi'), findsOneWidget);
    expect(find.textContaining('private storage'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'platform read failure is distinct from loading and unknown data',
    (tester) async {
      final store = _Store();
      await _mount(
        tester,
        store,
        const WindowPolicySnapshot(),
        snapshotError: true,
      );
      final failure = find.byKey(const ValueKey('window-status-error'));
      expect(failure, findsOneWidget);
      expect(
        tester.getSemantics(failure).label,
        contains('Pencere durumu okunamadı'),
      );
      expect(find.byKey(const ValueKey('window-status-loading')), findsNothing);
      expect(find.text('Tekrar Dene'), findsOneWidget);
      expect(find.textContaining('private platform'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('captured profile action expires across lifecycle changes', (
    tester,
  ) async {
    final store = _Store();
    await _mount(tester, store, const WindowPolicySnapshot(supported: true));
    final old = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('window-profile-panel')),
        )
        .onPressed!;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    old();
    await tester.pumpAndSettle();
    expect(store.writes, 0);
    expect(store.value, WindowProfile.adaptive.name);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fresh profile action works after lifecycle return', (
    tester,
  ) async {
    final store = _Store();
    await _mount(tester, store, const WindowPolicySnapshot(supported: true));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    final fresh = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('window-profile-panel')),
        )
        .onPressed!;
    fresh();
    await tester.pumpAndSettle();

    expect(store.writes, 1);
    expect(store.value, WindowProfile.panel.name);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        'window profile uses the shared tablet surface $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final store = _Store();
          try {
            await _mount(
              tester,
              store,
              const WindowPolicySnapshot(supported: true),
              size: Size(width, 1100),
              scale: 2,
              locale: Locale(language),
            );
            final l10n = AppLocalizations.of(
              tester.element(find.byType(WindowPanelScreen)),
            );

            expect(find.byType(SettingsSection), findsAtLeastNWidgets(1));
            expect(find.byType(SettingsActionTile), findsAtLeastNWidgets(2));
            final heading = find.byKey(
              const ValueKey('window-profile-heading'),
            );
            final headingNode = tester.getSemantics(heading);
            expect(headingNode.label, l10n.windowProfile);
            expect(headingNode.flagsCollection.isHeader, isTrue);
            expect(headingNode.flagsCollection.isButton, isFalse);

            final panel = find.byKey(const ValueKey('window-profile-panel'));
            final panelNode = tester.getSemantics(panel);
            expect(panelNode.label, contains(l10n.windowPanel));
            expect(panelNode.flagsCollection.isButton, isTrue);
            expect(panelNode.flagsCollection.isSelected, ui.Tristate.isFalse);
            expect(panelNode.rect.width, greaterThanOrEqualTo(48));
            expect(panelNode.rect.height, greaterThanOrEqualTo(48));

            final label = find.descendant(
              of: panel,
              matching: find.text(l10n.windowPanel),
            );
            Focus.of(tester.element(label)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(store.writes, 1);
            expect(store.value, WindowProfile.panel.name);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  for (final size in [
    const Size(320, 640),
    const Size(1000, 360),
    const Size(1366, 1024),
  ]) {
    testWidgets('window pane remains scrollable at $size and 2x text', (
      tester,
    ) async {
      await _mount(
        tester,
        _Store(),
        const WindowPolicySnapshot(supported: true),
        size: size,
        scale: 2,
      );
      await tester.scrollUntilVisible(
        find.text('Klavye ile gezinme'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Klavye ile gezinme').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
