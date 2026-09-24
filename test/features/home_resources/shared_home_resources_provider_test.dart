import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/home_resources/data/home_resources_providers.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resources_fixture.dart';

void main() {
  testWidgets(
    'shared catalog retains same-runtime rows as stale and clears on logout',
    (tester) async {
      final h = ResourceHarness();
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      final container = h.runtime(tester);
      final subscription = container.listen(
        sharedHomeResourcesProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await flush(tester);
      final catalog = container.read(sharedHomeResourcesProvider)!;
      expect(catalog.entries.map((entry) => entry.label), contains('Salon'));
      expect(catalog.stale, isFalse);

      final delayed = Completer<http.Response>();
      h.pending = delayed;
      unawaited(catalog.refresh());
      await flush(tester);
      expect(catalog.busy, isTrue);
      expect(catalog.stale, isTrue);
      expect(catalog.entries.map((entry) => entry.label), contains('Salon'));

      delayed.complete(
        h.json({
          'error': {'code': 'service_unavailable'},
        }, 503),
      );
      h.pending = null;
      await flush(tester);
      expect(catalog.failure, isNotNull);
      expect(catalog.stale, isTrue);
      expect(catalog.entries.map((entry) => entry.label), contains('Salon'));

      await h.account.signOut();
      await flush(tester);
      expect(catalog.entries, isEmpty);
    },
  );

  testWidgets(
    'shared catalog follows the bounded snapshot through every page',
    (tester) async {
      final h = ResourceHarness();
      h.resourceResponse = (request) {
        final after = request.url.queryParameters['after'];
        final id = after == null ? '1'.padLeft(32, '0') : '2'.padLeft(32, '0');
        return {
          'scope': h.fixture['context'],
          'userRevision': 7,
          'entries': [
            {
              'ref': {...h.fixture['context'] as Map, 'kind': 'room', 'id': id},
              'label': after == null ? 'First room' : 'Second room',
              'order': after == null ? 1 : 2,
              'revision': 1,
              'aclRevision': 1,
              'permissions': {'read': true, 'write': false},
            },
          ],
          'snapshot': 'a' * 64,
          'nextAfter': after == null ? id : null,
        };
      };
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      final container = h.runtime(tester);
      final subscription = container.listen(
        sharedHomeResourcesProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await flush(tester);
      final catalog = container.read(sharedHomeResourcesProvider)!;
      expect(catalog.entries.map((entry) => entry.label), [
        'First room',
        'Second room',
      ]);
      expect(catalog.nextAfter, isNull);
    },
  );
}
