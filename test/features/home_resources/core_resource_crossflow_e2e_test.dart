import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/app.dart';
import 'package:larenor/core/configuration_scope.dart';
import 'package:larenor/core/home_data_scope.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/dashboard_tile_button.dart';
import 'package:larenor/features/home_resources/data/home_resources_providers.dart';
import 'package:larenor/features/home_resources/domain/core_resource_binding.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String kind = 'room',
}) => {
  'scope': context,
  'userRevision': revision,
  'entries': [
    {
      'label': label,
      'order': 1,
      'ref': {...context, 'kind': kind, 'id': id},
      'revision': revision,
      'aclRevision': revision,
      'permissions': {'read': true, 'write': false},
    },
  ],
  'snapshot': revision.toString().padLeft(64, 'a'),
  'nextAfter': null,
};

String _dashboardRecord({
  required HomeDataScope scope,
  required int revision,
  required int resourceRevision,
  required int aclRevision,
  required int userRevision,
}) => jsonEncode({
  'version': 1,
  'scope': scope.toJson(),
  'revision': revision,
  'layout': DashboardLayout(
    tiles: [
      TileConfig(
        id: 'restored-core-card',
        type: TileType.coreResource,
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        coreResource: CoreResourceBinding(
          coreId: scope.coreId,
          homeId: scope.homeId,
          resourceId: '3' * 32,
          kind: HomeResourceKind.resource,
          resourceRevision: resourceRevision,
          aclRevision: aclRevision,
          userRevision: userRevision,
        ),
      ),
    ],
  ).toJson(),
});

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
      expect(find.byKey(ValueKey('core-room:${'1' * 32}')), findsOneWidget);
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

      expect(find.byKey(ValueKey('core-room:${'2' * 32}')), findsOneWidget);
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

  testWidgets(
    'return restore remount keeps a Core card inert until exact refetch and logout retires it again',
    (tester) async {
      final harness = ResourceHarness();
      final scopeA = HomeDataScope.fromJson({
        'coreId': 'a' * 32,
        'homeId': 'b' * 32,
        'userId': harness.userId,
      });
      await harness.mount(
        tester,
        preferences: {
          scopeA.storageKey: _dashboardRecord(
            scope: scopeA,
            revision: 4,
            resourceRevision: 1,
            aclRevision: 2,
            userRevision: 2,
          ),
        },
      );
      await harness.signIn();
      await flush(tester);
      harness.router(tester).go('/dashboard');
      await flush(tester);

      final card = find.byKey(ValueKey('core-resource-card-${'3' * 32}'));
      expect(card, findsOneWidget);
      expect(tester.widget<DashboardTileButton>(card).onPressed, isNotNull);

      await harness.account.signOut();
      await flush(tester);
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
      harness.router(tester).go('/dashboard');
      await flush(tester);
      expect(card, findsNothing);

      await harness.account.signOut();
      await flush(tester);
      final exactA = _catalog(
        context: Map<String, Object?>.from(harness.fixture['context'] as Map),
        label: 'Restored lamp',
        id: '3' * 32,
        revision: 5,
        kind: 'resource',
      );
      final pending = Completer<http.Response>();
      harness
        ..userId = scopeA.userId
        ..contextResponse = harness.fixture['context']
        ..response = exactA
        ..pending = pending;
      await harness.signIn();
      await flush(tester);

      final context = tester.element(find.byType(LarenorApp));
      final restore = ConfigurationScope.restore(
        context,
        operation: () async {
          final preferences = await SharedPreferences.getInstance();
          await preferences.setString(
            scopeA.storageKey,
            _dashboardRecord(
              scope: scopeA,
              revision: 5,
              resourceRevision: 5,
              aclRevision: 5,
              userRevision: 5,
            ),
          );
        },
        progressLabel: 'Restoring',
        failureLabel: 'Restore failed',
        continueLabel: 'Continue',
      );
      await tester.pump();
      await tester.pump();
      await restore;
      await flush(tester);
      harness.router(tester).go('/dashboard');
      await flush(tester);

      expect(card, findsOneWidget);
      expect(tester.widget<DashboardTileButton>(card).onPressed, isNull);

      pending.complete(harness.json(exactA));
      harness.pending = null;
      await flush(tester);
      expect(tester.widget<DashboardTileButton>(card).onPressed, isNotNull);
      final oldOpen = tester.widget<DashboardTileButton>(card).onPressed!;

      await harness.account.signOut();
      await flush(tester);
      oldOpen();
      await flush(tester);
      expect(
        find.byKey(const ValueKey('core-resource-destination')),
        findsNothing,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LarenorApp)),
        listen: false,
      );
      expect(container.read(sharedHomeResourcesProvider), isNull);
      expect(harness.haReads, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
