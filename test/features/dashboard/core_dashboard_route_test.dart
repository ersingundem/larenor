import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/presentation/home_dashboard_screen.dart';
import 'package:larenor/features/dashboard/presentation/dashboard_widget_picker_screen.dart';
import 'package:larenor/features/home_resources/presentation/core_resource_picker_screen.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/dashboard/presentation/tiles/dashboard_tile_button.dart';
import 'package:larenor/features/home_resources/data/home_resources_providers.dart';

import '../../core/home_scope_fixture.dart' show flush;
import '../home_resources/home_resources_fixture.dart';

void main() {
  for (final (locale, width) in [
    ('en', 600.0),
    ('en', 1200.0),
    ('tr', 600.0),
    ('tr', 1200.0),
  ]) {
    testWidgets(
      '$locale verified Core dashboard stays off Direct HA at ${width.toInt()}px and 2x',
      (tester) async {
        final harness = ResourceHarness();
        await harness.mount(tester, locale: locale, width: width, scale: 2);
        await harness.signIn();
        await flush(tester);

        unawaited(harness.router(tester).push('/dashboard'));
        await flush(tester);

        expect(find.byType(HomeDashboardScreen), findsOneWidget);
        expect(harness.haReads, 0);

        final beforeRefresh = harness.resourceReads;
        await tester.drag(find.byType(CustomScrollView), const Offset(0, 360));
        await tester.pump(const Duration(seconds: 1));
        await flush(tester);

        expect(harness.resourceReads, greaterThan(beforeRefresh));
        expect(harness.haReads, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Core card becomes inert while stale and after revocation', (
    tester,
  ) async {
    final harness = ResourceHarness();
    await harness.mount(tester, width: 600);
    await harness.signIn();
    await flush(tester);
    unawaited(harness.router(tester).push('/dashboard'));
    await flush(tester);

    await tester.tap(find.byIcon(CupertinoIcons.add_circled).first);
    await flush(tester);
    await tester.tap(find.text('Add Widget'));
    await flush(tester);
    await tester.tap(find.byKey(const ValueKey('widget-kind-coreResource')));
    await flush(tester);
    await tester.tap(
      find.byKey(
        const ValueKey('core-resource-picker-33333333333333333333333333333333'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CoreResourcePickerScreen), findsNothing);
    expect(find.byType(DashboardWidgetPickerScreen), findsNothing);
    expect(find.byType(HomeDashboardScreen), findsOneWidget);
    final layout = harness.runtime(tester).read(dashboardLayoutProvider).value;
    expect(
      layout?.tiles.map((tile) => tile.type.name),
      contains('coreResource'),
    );

    final card = find.byKey(
      const ValueKey('core-resource-card-33333333333333333333333333333333'),
    );
    expect(card, findsOneWidget);
    expect(tester.widget<DashboardTileButton>(card).onPressed, isNotNull);
    expect(harness.haReads, 0);

    final catalog = harness.runtime(tester).read(sharedHomeResourcesProvider)!;
    final delayed = Completer<http.Response>();
    harness.pending = delayed;
    unawaited(catalog.refresh());
    await flush(tester);
    expect(tester.widget<DashboardTileButton>(card).onPressed, isNull);

    delayed.complete(
      harness.json({
        'scope': harness.fixture['context'],
        'userRevision': 3,
        'entries': <Object>[],
        'snapshot': 'f' * 64,
        'nextAfter': null,
      }),
    );
    harness.pending = null;
    await flush(tester);

    expect(card, findsOneWidget);
    expect(tester.widget<DashboardTileButton>(card).onPressed, isNull);
    expect(harness.haReads, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Core room is created bound and revoked without Direct HA', (
    tester,
  ) async {
    final harness = ResourceHarness();
    await harness.mount(tester, width: 1200);
    await harness.signIn();
    await flush(tester);
    unawaited(harness.router(tester).push('/dashboard'));
    await flush(tester);

    await tester.tap(find.text('Add a room').last);
    await flush(tester);
    await tester.tap(
      find.byKey(
        const ValueKey('core-resource-picker-11111111111111111111111111111111'),
      ),
    );
    await tester.pumpAndSettle();

    final layout = harness.runtime(tester).read(dashboardLayoutProvider).value!;
    expect(layout.rooms, hasLength(1));
    expect(layout.rooms.single.name, 'Salon');
    expect(layout.rooms.single.entityIds, isEmpty);
    expect(layout.rooms.single.coreResource?.resourceId, '1' * 32);
    final card = find.byKey(
      const ValueKey('core-resource-card-11111111111111111111111111111111'),
    );
    expect(card, findsOneWidget);
    expect(tester.widget<DashboardTileButton>(card).onPressed, isNotNull);

    harness.response = harness.fixture['revokedList'];
    await harness.runtime(tester).read(sharedHomeResourcesProvider)!.refresh();
    await flush(tester);

    expect(card, findsOneWidget);
    expect(tester.widget<DashboardTileButton>(card).onPressed, isNull);
    expect(harness.haReads, 0);
    expect(tester.takeException(), isNull);
  });
}
