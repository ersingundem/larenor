import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/home_resources/data/home_resources_providers.dart';

import '../../../core/home_scope_fixture.dart' show flush;
import '../../home_resources/home_resources_fixture.dart';

Future<void> openSearch(ResourceHarness h, WidgetTester tester) async {
  unawaited(h.router(tester).push('/search'));
  await flush(tester);
  await tester.enterText(find.byType(CupertinoSearchTextField), 'Salon');
  await tester.pump(const Duration(milliseconds: 151));
  await tester.pump();
}

void main() {
  testWidgets(
    'verified Core search uses authorized catalog and opens exact row',
    (tester) async {
      final h = ResourceHarness();
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      await openSearch(h, tester);
      final result = find.byKey(ValueKey('core-room:${'1' * 32}'));
      expect(result, findsOneWidget);
      expect(find.byKey(const ValueKey('room:living')), findsNothing);
      await tester.tap(result);
      await flush(tester);
      expect(
        find.byKey(const ValueKey('core-resource-destination')),
        findsOneWidget,
      );
      expect(find.text('Salon'), findsOneWidget);
    },
  );

  testWidgets('same-runtime stale row remains visible but inert then revokes', (
    tester,
  ) async {
    final h = ResourceHarness();
    await h.mount(tester);
    await h.signIn();
    await flush(tester);
    await openSearch(h, tester);
    final container = h.runtime(tester);
    final catalog = container.read(sharedHomeResourcesProvider)!;
    final delayed = Completer<http.Response>();
    h.pending = delayed;
    unawaited(catalog.refresh());
    await flush(tester);
    final result = find.byKey(ValueKey('core-room:${'1' * 32}'));
    expect(result, findsOneWidget);
    expect(
      tester
          .widget<CupertinoButton>(
            find.descendant(of: result, matching: find.byType(CupertinoButton)),
          )
          .onPressed,
      isNull,
    );
    delayed.complete(h.json(h.fixture['revokedList']));
    h.pending = null;
    await flush(tester);
    expect(result, findsNothing);
    expect(
      find.byKey(const ValueKey('core-resource-destination')),
      findsNothing,
    );
  });
}
