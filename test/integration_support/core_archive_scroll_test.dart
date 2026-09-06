import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/core_archive_journey.dart';
import '../features/home_scope/core_layout_archive_ui_fixture.dart';

void main() {
  testWidgets('archive journey scrolls the actual vertical page with password fields mounted', (tester) async {
    final app = ArchiveHarness();
    await app.mount(tester);
    await app.open(tester);
    tester.view.physicalSize = const Size(600, 500);
    await flush(tester);
    final page = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    final position = tester.state<ScrollableState>(page).position;
    position.jumpTo(position.maxScrollExtent);
    await flush(tester);
    expect(find.byKey(const ValueKey('core-layout-archive-repeat')), findsOneWidget);
    expect(find.byType(Scrollable).evaluate().length, greaterThan(1));
    expect(position.pixels, greaterThan(0));
    await coreArchiveJourneyTop(tester);
    expect(position.pixels, 0);
    final refresh = find.byKey(const ValueKey('core-layout-archive-refresh'));
    expect(refresh.hitTestable(), findsOneWidget);
  });
}
