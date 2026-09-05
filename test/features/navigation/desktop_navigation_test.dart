import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/shared/widgets/app_navigation_bar.dart';
import 'package:larenor/core/router.dart';
import 'package:larenor/features/navigation/search/presentation/local_search_screen.dart';

import 'app_navigation_test.dart' show openApp;

Future<void> _control(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [
    const Size(320, 640),
    const Size(600, 360),
    const Size(999, 600),
    const Size(1000, 360),
    const Size(1280, 720),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('navigation fits $size at $scale text', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final container = await openApp(tester);
        final router = container.read(routerProvider);
        for (final route in ['/', '/media', '/routines', '/system']) {
          router.go(route);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: route);
        }
        if (size.width >= 1000) {
          final sidebar = find.byKey(const PageStorageKey('app-sidebar'));
          final settings = find.descendant(
            of: sidebar,
            matching: find.text('Settings'),
          );
          await tester.scrollUntilVisible(
            settings,
            180,
            scrollable: find
                .descendant(of: sidebar, matching: find.byType(Scrollable))
                .first,
          );
          await tester.pumpAndSettle();
          expect(settings.hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });
    }
  }

  testWidgets(
    'Ctrl navigation preserves the selected room; search reuses focus and Escape returns',
    (tester) async {
      final container = await openApp(tester);
      final router = container.read(routerProvider);
      router.go('/rooms/salon');
      await tester.pumpAndSettle();
      await _control(tester, LogicalKeyboardKey.digit2);
      expect(router.routeInformationProvider.value.uri.path, '/media');
      await _control(tester, LogicalKeyboardKey.digit1);
      expect(router.routeInformationProvider.value.uri.path, '/rooms/salon');
      await _control(tester, LogicalKeyboardKey.keyK);
      expect(find.byType(LocalSearchScreen), findsOneWidget);
      expect(router.canPop(), isTrue);
      var field = tester.widget<CupertinoSearchTextField>(
        find.byType(CupertinoSearchTextField),
      );
      expect(field.focusNode!.hasFocus, isTrue);
      await _control(tester, LogicalKeyboardKey.keyK);
      expect(find.byType(LocalSearchScreen), findsOneWidget);
      field = tester.widget<CupertinoSearchTextField>(
        find.byType(CupertinoSearchTextField),
      );
      expect(field.focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/rooms/salon');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'navigation shortcuts cannot dismiss or confirm an active dialog',
    (tester) async {
      final container = await openApp(tester);
      final router = container.read(routerProvider);
      var sends = 0;
      final context = tester.element(find.byType(AppNavigationBar));
      final pending = showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('Confirm fixture action'),
          actions: [
            CupertinoDialogAction(
              onPressed: () {
                sends++;
                Navigator.pop(dialogContext);
              },
              child: const Text('Confirm'),
            ),
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await _control(tester, LogicalKeyboardKey.keyK);
      await _control(tester, LogicalKeyboardKey.digit2);
      expect(router.routeInformationProvider.value.uri.path, '/');
      expect(find.text('Confirm fixture action'), findsOneWidget);
      expect(sends, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await pending;
      expect(sends, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings PIN route does not inherit root shortcuts', (
    tester,
  ) async {
    final container = await openApp(tester, pin: '1234');
    final router = container.read(routerProvider);
    router.push('/settings');
    await tester.pumpAndSettle();
    await _control(tester, LogicalKeyboardKey.keyK);
    await _control(tester, LogicalKeyboardKey.digit3);
    expect(find.text('Unlock'), findsOneWidget);
    expect(router.canPop(), isTrue);
    expect(find.byType(LocalSearchScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
