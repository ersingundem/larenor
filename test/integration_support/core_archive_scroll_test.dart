import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_scope/presentation/home_source_screen.dart';

import '../../integration_test/support/core_archive_journey.dart';
import '../features/home_scope/core_layout_archive_ui_fixture.dart';

void main() {
  testWidgets(
    'archive journey discovers its Home Source entry in a small 2x viewport',
    (tester) async {
      final app = ArchiveHarness();
      await app.mount(tester, width: 420, height: 400, scale: 2);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await flush(tester);

      expect(find.byType(HomeSourceScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('core-layout-archive-entry')),
        findsNothing,
      );

      await coreArchiveJourneyVisible(tester, 'core-layout-archive-entry');

      expect(
        find.byKey(const ValueKey('core-layout-archive-entry')).hitTestable(),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'archive journey waits for its route before selecting a page scrollable',
    (tester) async {
      final oldWarnings = WidgetController.hitTestWarningShouldBeFatal;
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(
        () => WidgetController.hitTestWarningShouldBeFatal = oldWarnings,
      );
      final app = ArchiveHarness();
      await app.mount(tester, width: 420, height: 400, scale: 2);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await flush(tester);
      await coreArchiveJourneyVisible(tester, 'core-layout-archive-entry');

      // Navigator.push runs on pointer-up, while the destination is built by
      // the next frame. Exercise that exact no-pump interval from the journey.
      await tester.tap(find.byKey(const ValueKey('core-layout-archive-entry')));

      await coreArchiveJourneyVisible(tester, 'core-layout-archive-repeat');

      expect(
        find.byKey(const ValueKey('core-layout-archive-repeat')).hitTestable(),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'archive journey scrolls the actual vertical page with password fields mounted',
    (tester) async {
      final app = ArchiveHarness();
      await app.mount(tester);
      await app.open(tester);
      tester.view.physicalSize = const Size(600, 500);
      await flush(tester);
      final page = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(page).position;
      position.jumpTo(position.maxScrollExtent);
      await flush(tester);
      expect(
        find.byKey(const ValueKey('core-layout-archive-repeat')),
        findsOneWidget,
      );
      expect(find.byType(Scrollable).evaluate().length, greaterThan(1));
      expect(position.pixels, greaterThan(0));
      await coreArchiveJourneyTop(tester);
      expect(position.pixels, 0);
      final refresh = find.byKey(const ValueKey('core-layout-archive-refresh'));
      expect(refresh.hitTestable(), findsOneWidget);
    },
  );
}
