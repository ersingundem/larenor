import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resources_fixture.dart';

Map<String, Object?> _context(String core, String home) => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
};

Map<String, Object?> _catalog({
  required Map<String, Object?> context,
  required String label,
  required String id,
  required int revision,
}) => {
  'scope': context,
  'userRevision': revision,
  'entries': [
    {
      'label': label,
      'order': 1,
      'ref': {...context, 'kind': 'room', 'id': id},
      'revision': revision,
      'aclRevision': revision,
      'permissions': {'read': true, 'write': false},
    },
  ],
  'snapshot': revision.toString().padLeft(64, 'a'),
  'nextAfter': null,
};

Future<void> _openSearch(
  ResourceHarness harness,
  WidgetTester tester,
  String query,
) async {
  harness.router(tester).go('/search');
  await flush(tester);
  await tester.enterText(find.byType(CupertinoSearchTextField), query);
  await tester.pump(const Duration(milliseconds: 151));
  await flush(tester);
}

void main() {
  testWidgets(
    'same URL account replacement publishes only the current Core catalog and search rows',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);

      await _openSearch(harness, tester, 'Salon');
      expect(
        find.byKey(ValueKey('core-room:${'1' * 32}')),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('core-room:${'2' * 32}')), findsNothing);

      await harness.account.signOut();
      await flush(tester);
      expect(find.byKey(ValueKey('core-room:${'1' * 32}')), findsNothing);

      final contextB = _context('c' * 32, 'd' * 32);
      harness
        ..userId = '8' * 32
        ..contextResponse = contextB
        ..response = _catalog(
          context: contextB,
          label: 'B study',
          id: '2' * 32,
          revision: 7,
        );
      await harness.signIn();
      await flush(tester);
      await _openSearch(harness, tester, 'study');

      expect(
        find.byKey(ValueKey('core-room:${'2' * 32}')),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('core-room:${'1' * 32}')), findsNothing);
      expect(
        harness.requests
            .where((request) => request.url.path.contains('/home-resources/'))
            .length,
        greaterThanOrEqualTo(2),
      );
      expect(harness.haReads, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
