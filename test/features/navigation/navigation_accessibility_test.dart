import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/router.dart';

import 'app_navigation_test.dart' show openApp;

void main() {
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
    expect(container.read(routerProvider).routeInformationProvider.value.uri.path,
        '/media');
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
    final icon = tester.getRect(find.byIcon(CupertinoIcons.play_rectangle_fill).last);
    expect(icon.bottom + 4, lessThanOrEqualTo(label.top));
    expect(tester.takeException(), isNull);
  });
}
