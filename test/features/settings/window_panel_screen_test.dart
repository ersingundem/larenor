import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/settings/presentation/window_panel_screen.dart';
import 'package:larenor/features/settings/providers/window_profile_provider.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        windowProfileStoreProvider.overrideWithValue(store),
        windowPolicySnapshotProvider.overrideWith(
          (_) => Stream.value(snapshot),
        ),
      ],
      child: CupertinoApp(
        locale: const Locale('tr'),
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
