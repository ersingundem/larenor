import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';

import '../../core/home_scope_fixture.dart';

void main() {
  testWidgets(
    'verified Core offers explicit local layout preview only behind PIN',
    (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore);
      await h.mount(tester, pin: '1234');
      await h.signIn();
      await flush(tester);
      h.router(tester).push('/settings/home-source');
      await flush(tester);
      expect(
        find.byKey(const ValueKey('home-layout-preview-entry')),
        findsNothing,
      );
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await flush(tester);
      expect(
        find.byKey(const ValueKey('home-layout-preview-entry')),
        findsOneWidget,
      );
      expect(h.connectionReads, 0);
    },
  );
}
