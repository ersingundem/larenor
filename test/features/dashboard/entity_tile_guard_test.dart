import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/entity_tile.dart';
import 'package:larenor/features/dashboard/presentation/tiles/home_accessory_tile.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _entity = HaEntity(
  entityId: 'light.lamp',
  state: 'on',
  attributes: {'friendly_name': 'Original name'},
);
const _tile = TileConfig(
  id: 'tile',
  type: TileType.entity,
  x: 0,
  y: 0,
  width: 1,
  height: 1,
  entityId: 'light.lamp',
  title: 'Custom title',
);

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'http://fixture.invalid',
    token: 'fixture',
  );
  void change() => state = const AsyncData(
    HaConnectionConfig(baseUrl: 'http://other.invalid', token: 'other'),
  );
}

class _Entities extends Entities {
  int writes = 0;
  Completer<void>? pending;
  @override
  Future<Map<String, HaEntity>> build() async => {_entity.entityId: _entity};
  @override
  Future<void> toggle(HaEntity entity) async {
    writes++;
    await pending?.future;
  }

  void fail() {
    const failure = AsyncError<Map<String, HaEntity>>(
      'private-backend',
      StackTrace.empty,
    );
    // ignore: invalid_use_of_internal_member
    state = failure.copyWithPrevious(const AsyncData({'light.lamp': _entity}));
  }
}

class _Harness {
  final connection = _Connection();
  final entities = _Entities();
  final interaction = AppInteractionController();
  late ProviderContainer container;
  int menus = 0;
  Future<void> mount(WidgetTester tester) async {
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        connectionConfigProvider.overrideWith(() => connection),
        entitiesProvider.overrideWith(() => entities),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(interaction.dispose);
    final accountSubscription = container.listen(
      connectionConfigProvider,
      (_, _) {},
    );
    final statesSubscription = container.listen(entitiesProvider, (_, _) {});
    addTearDown(accountSubscription.close);
    addTearDown(statesSubscription.close);
    await container.read(connectionConfigProvider.future);
    await container.read(entitiesProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          builder: (_, child) =>
              AppInteractionScope(controller: interaction, child: child!),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CupertinoPageScaffold(
            child: Center(
              child: SizedBox(
                width: 220,
                height: 240,
                child: GestureDetector(
                  onLongPress: () => menus++,
                  child: const EntityTile(tile: _tile),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  VoidCallback tap(WidgetTester tester) => tester
      .widget<GestureDetector>(
        find
            .descendant(
              of: find.byType(HomeAccessoryTile),
              matching: find.byType(GestureDetector),
            )
            .first,
      )
      .onTap!;
}

void main() {
  testWidgets(
    'idle expires an accessory callback even when wake precedes the next frame',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final old = h.tap(tester);
      h.interaction.setActive(false);
      h.interaction.setActive(true);
      old();
      expect(h.entities.writes, 0);
      await tester.pumpAndSettle();
      h.tap(tester)();
      await tester.pumpAndSettle();
      expect(h.entities.writes, 1);
    },
  );

  testWidgets(
    'saved entity delegates guarded control and preserves custom title/menu',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      expect(find.text('Custom title'), findsOneWidget);
      expect(find.text('Original name'), findsNothing);
      expect(find.byType(CupertinoSwitch), findsNothing);
      await tester.longPress(find.byType(EntityTile));
      await tester.pumpAndSettle();
      expect(h.menus, 1);
      expect(h.entities.writes, 0);
    },
  );
  testWidgets('duplicate entity activation shares one pending guarded action', (
    tester,
  ) async {
    final h = _Harness();
    h.entities.pending = Completer<void>();
    await h.mount(tester);
    final callback = h.tap(tester);
    callback();
    callback();
    await tester.pump();
    expect(h.entities.writes, 1);
    h.entities.pending!.complete();
    await tester.pumpAndSettle();
  });
  testWidgets(
    'failed retained entity snapshot removes controls and old callback',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final callback = h.tap(tester);
      h.entities.fail();
      await tester.pumpAndSettle();
      callback();
      expect(find.byType(HomeAccessoryTile), findsNothing);
      expect(find.text('Custom title'), findsNothing);
      expect(find.textContaining('private-backend'), findsNothing);
      expect(h.entities.writes, 0);
    },
  );
  testWidgets(
    'account and background transitions reject previous entity callbacks',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final old = h.tap(tester);
      h.connection.change();
      await tester.pumpAndSettle();
      old();
      expect(h.entities.writes, 0);
      final foreground = h.tap(tester);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      foreground();
      expect(h.entities.writes, 0);
    },
  );
  testWidgets(
    'late failure after dispose never opens a dialog or touches ref',
    (tester) async {
      final h = _Harness();
      h.entities.pending = Completer<void>();
      await h.mount(tester);
      h.tap(tester)();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      h.entities.pending!.completeError(StateError('private-late-error'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
