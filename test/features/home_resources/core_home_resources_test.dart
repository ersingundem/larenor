import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../core/home_scope_fixture.dart' show flush, press;
import 'home_resources_fixture.dart';

void main() {
  testWidgets(
    'actual Core home displays permitted metadata and refresh removes revoked rows without HA',
    (tester) async {
      final h = ResourceHarness();
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      expect(find.byKey(const ValueKey('home-resources-list')), findsOneWidget);
      expect(find.byKey(ValueKey('home-resource-${'1' * 32}')), findsOneWidget);
      expect(find.text('Salon'), findsOneWidget);
      expect(h.resourceReads, 1);
      expect(h.haReads, 0);
      h.response = h.fixture['revokedList'];
      await press(tester, 'home-resources-refresh');
      expect(find.text('Salon'), findsNothing);
      expect(find.text('Okuma lambası'), findsOneWidget);
      h.response = h.fixture['emptyList'];
      await press(tester, 'home-resources-refresh');
      expect(
        find.byKey(const ValueKey('home-resources-empty')),
        findsOneWidget,
      );
      expect(h.resourceReads, 3);
      expect(h.authPosts, 1);
      expect(h.haReads, 0);
    },
  );
}
