import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/router.dart';
import 'package:larenor/shared/widgets/app_navigation_bar.dart';

import 'app_navigation_test.dart' show openApp;

void main() {
  testWidgets(
    'keyboard navigation keeps its room across the DeX sidebar breakpoint',
    (tester) async {
      tester.view.physicalSize = const Size(999, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = await openApp(tester);
      final router = container.read(routerProvider);
      router.go('/rooms/salon');
      await tester.pumpAndSettle();
      Focus.of(
        tester.element(
          find.descendant(
            of: find.byType(AppNavigationBar),
            matching: find.text('Home'),
          ),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/media');
      tester.view.physicalSize = const Size(1000, 600);
      await tester.pumpAndSettle();
      final home = find.descendant(
        of: find.byKey(const PageStorageKey('app-sidebar')),
        matching: find.text('Home'),
      );
      Focus.of(tester.element(home)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/rooms/salon');
      tester.view.physicalSize = const Size(999, 600);
      await tester.pumpAndSettle();
      expect(find.byType(AppNavigationBar), findsOneWidget);
      expect(router.routeInformationProvider.value.uri.path, '/rooms/salon');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a bottom destination can be focused and activated by keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = await openApp(tester);
    final media = find.text('Media').last;
    Focus.of(tester.element(media)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      container.read(routerProvider).routeInformationProvider.value.uri.path,
      '/media',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('large bottom labels leave visible space below their icons', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 360);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await openApp(tester);
    final label = tester.getRect(find.text('Media').last);
    final icon = tester.getRect(
      find.byIcon(CupertinoIcons.play_rectangle_fill).last,
    );
    expect(icon.bottom + 4, lessThanOrEqualTo(label.top));
    expect(tester.takeException(), isNull);
  });
}
