import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/presentation/widgets/entity_controls.dart';
import 'package:larenor/features/dashboard/presentation/widgets/more_info_sheet.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_tools/domain/ha_action.dart';
import 'package:larenor/features/ha_tools/presentation/ha_actions_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const lock = HaEntity(
  entityId: 'lock.front',
  state: 'locked',
  attributes: {'friendly_name': 'Front lock'},
);
const light = HaEntity(
  entityId: 'light.front',
  state: 'on',
  attributes: {'friendly_name': 'Living light', 'brightness': 128},
);
const cover = HaEntity(
  entityId: 'cover.front',
  state: 'open',
  attributes: {
    'friendly_name': 'Blind',
    'current_position': 50,
    'supported_features': 7,
  },
);

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'https://first.invalid',
    token: 'first-fixture',
  );
  void replace() => state = const AsyncData(
    HaConnectionConfig(
      baseUrl: 'https://second.invalid',
      token: 'second-fixture',
    ),
  );
  void reload() => state = const AsyncLoading<HaConnectionConfig?>()
      // ignore: invalid_use_of_internal_member
      .copyWithPrevious(state);
}

class _Entities extends Entities {
  _Entities(this.initial);
  final HaEntity initial;
  @override
  Future<Map<String, HaEntity>> build() async => {initial.entityId: initial};
  void replace(HaEntity entity) => state = AsyncData({entity.entityId: entity});
  void loading() => state = const AsyncLoading<Map<String, HaEntity>>()
      // ignore: invalid_use_of_internal_member
      .copyWithPrevious(state);
  void fail() => state =
      AsyncError<Map<String, HaEntity>>(
        StateError('private-backend'),
        StackTrace.current,
      )
      // ignore: invalid_use_of_internal_member
      .copyWithPrevious(state);
}

class _Repository extends DashboardRepository {
  DashboardLayout value = const DashboardLayout();
  int writes = 0;
  @override
  Future<DashboardLayout> load() async => value;
  @override
  Future<void> save(DashboardLayout next, {bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) throw StateError('expired');
    value = next;
    writes++;
  }
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(Duration.zero);
  }
}

class _Harness {
  _Harness({HaEntity initial = lock})
    : entity = ValueNotifier(initial),
      entities = _Entities(initial);
  final ValueNotifier<HaEntity> entity;
  final _Entities entities;
  final _Repository repository = _Repository();
  final visible = ValueNotifier(true);
  final first = <http.Request>[], second = <http.Request>[];
  Completer<http.Response>? response;
  Completer<void>? catalogGate;
  List<HaAction>? explicitCatalog;
  late ProviderContainer container;
  late HaRestClient firstClient, secondClient;
  _Connection get connection =>
      container.read(connectionConfigProvider.notifier) as _Connection;
  List<HaAction> get catalog =>
      explicitCatalog ??
      [
        for (final service in switch (entity.value.domain) {
          'lock' => ['lock', 'unlock'],
          'light' => ['turn_on', 'turn_off'],
          'cover' => ['open_cover', 'close_cover', 'set_cover_position'],
          'select' => ['select_option'],
          _ => ['media_play', 'volume_set'],
        })
          HaAction(
            domain: entity.value.domain,
            service: service,
            metadata: const {'target': <String, dynamic>{}},
          ),
      ];
  Future<void> mount(
    WidgetTester tester, {
    String screen = 'controls',
    Size size = const Size(650, 1100),
    double scale = 1,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    firstClient = HaRestClient(
      baseUrl: 'https://first.invalid',
      token: 'fixture',
      httpClient: MockClient((request) async {
        first.add(request);
        return response == null ? http.Response('[]', 200) : response!.future;
      }),
    );
    secondClient = HaRestClient(
      baseUrl: 'https://second.invalid',
      token: 'fixture',
      httpClient: MockClient((request) async {
        second.add(request);
        return http.Response('[]', 200);
      }),
    );
    addTearDown(firstClient.dispose);
    addTearDown(secondClient.dispose);
    addTearDown(entity.dispose);
    addTearDown(visible.dispose);
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        connectionConfigProvider.overrideWith(_Connection.new),
        entitiesProvider.overrideWith(() => entities),
        dashboardRepositoryProvider.overrideWith((_) => repository),
        haWebSocketClientProvider.overrideWith((_) => null),
        haRestClientProvider.overrideWith((ref) {
          final value = ref.watch(connectionConfigProvider);
          return value.isLoading || value.hasError
              ? null
              : value.value?.baseUrl == 'https://first.invalid'
              ? firstClient
              : secondClient;
        }),
        haActionsProvider.overrideWith((ref) async {
          await catalogGate?.future;
          return catalog;
        }),
      ],
    );
    addTearDown(container.dispose);
    final connectionListener = container.listen(
      connectionConfigProvider,
      (_, _) {},
    );
    final entityListener = container.listen(entitiesProvider, (_, _) {});
    addTearDown(connectionListener.close);
    addTearDown(entityListener.close);
    await container.read(connectionConfigProvider.future);
    await container.read(entitiesProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: ValueListenableBuilder(
            valueListenable: visible,
            builder: (context, shown, _) => TickerMode(
              enabled: shown,
              child: ValueListenableBuilder(
                valueListenable: entity,
                builder: (context, value, _) => CupertinoPageScaffold(
                  child: SafeArea(
                    child: screen == 'more'
                        ? EntityMoreInfo(entityId: value.entityId, asPage: true)
                        : screen == 'action'
                        ? HaActionScreen(
                            action: catalog.last,
                            entityId: value.entityId,
                          )
                        : screen == 'actions'
                        ? HaActionsScreen(entityId: value.entityId)
                        : SingleChildScrollView(
                            child: EntityControls(entity: value),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  VoidCallback control(WidgetTester tester, String name) => tester
      .widget<CupertinoButton>(find.byKey(ValueKey('entity-control-$name')))
      .onPressed!;
  Future<void> unlock(WidgetTester tester) async {
    control(tester, 'unlock')();
    await frames(tester);
    await tester.pump(const Duration(milliseconds: 400));
  }

  VoidCallback confirm(WidgetTester tester, String text) => tester
      .widget<CupertinoDialogAction>(
        find.widgetWithText(CupertinoDialogAction, text),
      )
      .onPressed!;
  Future<void> settleDialog(WidgetTester tester) async {
    await frames(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await frames(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await frames(tester);
  }
}

void main() {
  for (final cause in [
    'account',
    'loading',
    'entity_loading',
    'entity_error',
    'background',
    'hidden',
    'swap',
  ]) {
    testWidgets(
      'lock confirmation $cause invalidates old callback with zero server writes',
      (tester) async {
        final h = _Harness();
        await h.mount(tester);
        await h.unlock(tester);
        final old = h.confirm(tester, 'Unlock');
        switch (cause) {
          case 'account':
            h.connection.replace();
          case 'loading':
            h.connection.reload();
          case 'entity_loading':
            h.entities.loading();
          case 'entity_error':
            h.entities.fail();
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
          case 'hidden':
            h.visible.value = false;
          case 'swap':
            final next = lock.copyWith(entityId: 'lock.other');
            h.entities.replace(next);
            h.entity.value = next;
        }
        await frames(tester);
        old();
        await h.settleDialog(tester);
        expect(h.first, isEmpty);
        expect(h.second, isEmpty);
        expect(find.byType(CupertinoAlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await h.unmount(tester);
        if (cause == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
      },
    );
  }
  testWidgets(
    'double lock popup and approval still produce one captured request',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final button = h.control(tester, 'unlock');
      button();
      button();
      await h.settleDialog(tester);
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      final confirm = h.confirm(tester, 'Unlock');
      confirm();
      confirm();
      await h.settleDialog(tester);
      expect(h.first, hasLength(1));
      expect(h.first.single.url.host, 'first.invalid');
      expect(h.second, isEmpty);
      await h.unmount(tester);
    },
  );
  testWidgets(
    'catalog refresh retains no active controls or old command authority',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.unlock(tester);
      final confirm = h.confirm(tester, 'Unlock');
      h.catalogGate = Completer<void>();
      h.container.invalidate(haActionsProvider);
      await frames(tester);
      confirm();
      await h.settleDialog(tester);
      expect(h.first, isEmpty);
      expect(h.second, isEmpty);
      h.catalogGate!.completeError(StateError('private-catalog'));
      await frames(tester);
      expect(find.textContaining('private-catalog'), findsNothing);
      expect(find.byKey(const ValueKey('entity-control-unlock')), findsNothing);
      await h.unmount(tester);
    },
  );
  testWidgets(
    'old slider callbacks after entity reuse and nonfinite gestures are inert',
    (tester) async {
      final h = _Harness(initial: cover);
      await h.mount(tester);
      final slider = tester.widget<CupertinoSlider>(
        find.byType(CupertinoSlider),
      );
      slider.onChanged!(double.nan);
      slider.onChangeEnd!(double.infinity);
      expect(h.first, isEmpty);
      final next = cover.copyWith(entityId: 'cover.other');
      h.entities.replace(next);
      h.entity.value = next;
      await frames(tester);
      slider.onChanged!(70);
      slider.onChangeEnd!(70);
      await frames(tester);
      expect(h.first, isEmpty);
      expect(tester.takeException(), isNull);
      await h.unmount(tester);
    },
  );
  testWidgets(
    'choice pending guard prevents duplicate sheets and validates fresh option list',
    (tester) async {
      const select = HaEntity(
        entityId: 'select.mode',
        state: 'A',
        attributes: {
          'options': ['A', 'B'],
        },
      );
      final h = _Harness(initial: select);
      await h.mount(tester);
      final tile = tester.widget<CupertinoListTile>(
        find.byType(CupertinoListTile),
      );
      tile.onTap!();
      tile.onTap!();
      await h.settleDialog(tester);
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      h.entities.replace(
        select.copyWith(
          attributes: {
            'options': ['A'],
          },
        ),
      );
      await frames(tester);
      tester
          .widget<CupertinoActionSheetAction>(
            find.widgetWithText(CupertinoActionSheetAction, 'B'),
          )
          .onPressed();
      await h.settleDialog(tester);
      expect(h.first, isEmpty);
      await h.unmount(tester);
    },
  );
  testWidgets(
    'MoreInfo hides retained failed state and stale light callbacks cannot send',
    (tester) async {
      final h = _Harness(initial: light);
      await h.mount(tester, screen: 'more');
      final toggle = tester
          .widget<CupertinoSwitch>(find.byType(CupertinoSwitch))
          .onChanged!;
      final slider = tester.widget<CupertinoSlider>(
        find.byType(CupertinoSlider),
      );
      h.entities.fail();
      await frames(tester);
      expect(find.text('Living light'), findsNothing);
      expect(find.byType(CupertinoSwitch), findsNothing);
      toggle(false);
      slider.onChanged!(0.8);
      slider.onChangeEnd!(0.8);
      await frames(tester);
      expect(h.first, isEmpty);
      expect(tester.takeException(), isNull);
      await h.unmount(tester);
    },
  );
  testWidgets(
    'MoreInfo light toggle and brightness send one request only at gesture end',
    (tester) async {
      final h = _Harness(initial: light);
      await h.mount(tester, screen: 'more');
      final slider = tester.widget<CupertinoSlider>(
        find.byType(CupertinoSlider),
      );
      for (var i = 0; i < 20; i++) {
        slider.onChanged!(i / 20);
      }
      expect(h.first, isEmpty);
      slider.onChangeEnd!(0.75);
      await tester.pumpAndSettle();
      expect(h.first, hasLength(1));
      expect(jsonDecode(h.first.single.body)['brightness_pct'], 75);
      await h.unmount(tester);
    },
  );
  testWidgets(
    'favorite queued before account change never writes old source layout',
    (tester) async {
      final h = _Harness(initial: light);
      await h.mount(tester, screen: 'more');
      final gate = Completer<void>();
      final blocked = ConfigurationWrites.run(() => gate.future);
      final star = find.ancestor(
        of: find.byIcon(CupertinoIcons.star),
        matching: find.byType(CupertinoButton),
      );
      final callback = tester.widget<CupertinoButton>(star).onPressed!;
      callback();
      callback();
      await frames(tester);
      h.connection.replace();
      await frames(tester);
      gate.complete();
      await blocked;
      await frames(tester);
      expect(h.repository.writes, 0);
      expect(h.repository.value.favoriteEntityIds, isEmpty);
      expect(tester.takeException(), isNull);
      await h.unmount(tester);
    },
  );
  testWidgets('AllActions captured callback cannot open on another account', (
    tester,
  ) async {
    final h = _Harness(initial: light);
    await h.mount(tester, screen: 'more');
    final l10n = AppLocalizations.of(
      tester.element(find.byType(EntityMoreInfo)),
    );
    final callback = tester
        .widget<CupertinoButton>(
          find.widgetWithText(CupertinoButton, l10n.haAllActions),
        )
        .onPressed!;
    h.connection.replace();
    await frames(tester);
    callback();
    await frames(tester);
    expect(find.byType(HaActionsScreen), findsNothing);
    expect(h.first, isEmpty);
    await h.unmount(tester);
  });
  for (final cause in ['account', 'background', 'hidden']) {
    testWidgets(
      'generic HA action confirmation $cause never crosses source lease',
      (tester) async {
        final h = _Harness();
        await h.mount(tester, screen: 'action');
        final run = find.widgetWithText(CupertinoButton, 'Run');
        await tester.ensureVisible(run);
        tester.widget<CupertinoButton>(run).onPressed!();
        await h.settleDialog(tester);
        final confirm = h.confirm(tester, 'Run');
        if (cause == 'account') h.connection.replace();
        if (cause == 'hidden') h.visible.value = false;
        if (cause == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        }
        await frames(tester);
        confirm();
        await h.settleDialog(tester);
        expect(h.first, isEmpty);
        expect(h.second, isEmpty);
        expect(find.byType(CupertinoAlertDialog), findsNothing);
        await h.unmount(tester);
        if (cause == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
      },
    );
  }
  testWidgets(
    'nested MoreInfo to action route remains usable but account invalidates its dialog',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, screen: 'more');
      final labels = AppLocalizations.of(
        tester.element(find.byType(EntityMoreInfo)),
      );
      final all = find.widgetWithText(CupertinoButton, labels.haAllActions);
      await tester.ensureVisible(all);
      tester.widget<CupertinoButton>(all).onPressed!();
      await tester.pumpAndSettle();
      expect(find.byType(HaActionsScreen), findsOneWidget);
      final tile = find.widgetWithText(CupertinoListTile, 'lock.unlock');
      await tester.ensureVisible(tile);
      tester.widget<CupertinoListTile>(tile).onTap!();
      await tester.pumpAndSettle();
      expect(find.byType(HaActionScreen), findsOneWidget);
      final run = find.widgetWithText(CupertinoButton, 'Run');
      await tester.ensureVisible(run);
      tester.widget<CupertinoButton>(run).onPressed!();
      await h.settleDialog(tester);
      final confirm = h.confirm(tester, 'Run');
      h.connection.replace();
      await frames(tester);
      confirm();
      await h.settleDialog(tester);
      expect(h.first, isEmpty);
      expect(h.second, isEmpty);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await h.unmount(tester);
    },
  );
  testWidgets(
    'late command failure after disposal is handled without UI access',
    (tester) async {
      final h = _Harness(initial: cover);
      h.response = Completer<http.Response>();
      await h.mount(tester);
      h.control(tester, 'open_cover')();
      await frames(tester);
      await h.unmount(tester);
      h.response!.complete(http.Response('private failure', 500));
      await frames(tester);
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in [const Size(320, 900), const Size(1280, 900)]) {
    testWidgets('lock and detail action flows fit large text ${size.width}', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester, screen: 'more', size: size, scale: 2);
      await h.unlock(tester);
      await h.settleDialog(tester);
      expect(tester.takeException(), isNull);
      expect(h.first, isEmpty);
      await h.unmount(tester);
    });
  }
}
