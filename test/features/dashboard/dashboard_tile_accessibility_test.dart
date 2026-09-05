import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/dashboard/presentation/dashboard_card_presentation.dart';
import 'package:larenor/features/dashboard/presentation/tiles/home_accessory_tile.dart';
import 'package:larenor/features/dashboard/presentation/tiles/dashboard_tile_button.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/features/dashboard/presentation/tiles/service_tile_shell.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Entities extends Entities {
  int calls = 0;
  Completer<void>? pending;
  @override
  Future<Map<String, HaEntity>> build() async {
    // The real dashboard watches this provider; the isolated tile harness
    // retains the same notifier across successive keyboard activations.
    ref.keepAlive();
    return {};
  }

  @override
  Future<void> toggle(HaEntity entity) async {
    calls++;
    await pending?.future;
  }
}

Future<void> mount(
  WidgetTester tester,
  WidgetBuilder child, {
  String language = 'en',
  Brightness brightness = Brightness.light,
  double scale = 1,
  _Entities? entities,
  AppInteractionController? interaction,
  ValueNotifier<bool>? visible,
  GlobalKey<NavigatorState>? navigator,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        wellbeingPrivateEntityIdsProvider.overrideWithValue(
          const AsyncData({}),
        ),
        if (entities != null) entitiesProvider.overrideWith(() => entities),
      ],
      child: CupertinoApp(
        navigatorKey: navigator,
        theme: larenorTheme(brightness: brightness),
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) {
          Widget content = child!;
          if (visible != null) {
            final body = content;
            content = ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, active, _) =>
                  TickerMode(enabled: active, child: body),
            );
          }
          if (interaction != null)
            content = AppInteractionScope(
              controller: interaction,
              child: content,
            );
          return MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: content,
          );
        },
        home: CupertinoPageScaffold(
          child: Center(child: Builder(builder: child)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<SemanticsNode> buttons(WidgetTester tester) {
  final result = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    if (node.getSemanticsData().flagsCollection.isButton) result.add(node);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return result;
}

void main() {
  for (final change in [
    'idle-wake',
    'hidden',
    'background-wake',
    'covered',
    'reparent',
    'disposed',
  ]) {
    testWidgets(
      'service navigation captured before $change cannot reopen a route',
      (tester) async {
        final interaction = AppInteractionController();
        final visible = ValueNotifier(true);
        final navigator = GlobalKey<NavigatorState>();
        addTearDown(interaction.dispose);
        addTearDown(visible.dispose);
        var routes = 0;
        Widget tile(BuildContext context) => SizedBox(
          width: 180,
          height: dashboardServiceRowExtent(context),
          child: ServiceTileShell(
            icon: CupertinoIcons.play,
            title: 'Jellyfin',
            connected: true,
            lines: const ['Synthetic library'],
            onTap: () {
              routes++;
              navigator.currentState!.push(
                CupertinoPageRoute<void>(
                  builder: (_) =>
                      const Center(child: Text('Service destination')),
                ),
              );
            },
          ),
        );
        await mount(
          tester,
          tile,
          interaction: interaction,
          visible: visible,
          navigator: navigator,
        );
        final captured = tester
            .widget<CupertinoButton>(find.byType(CupertinoButton))
            .onPressed!;
        switch (change) {
          case 'idle-wake':
            interaction.setActive(false);
            interaction.setActive(true);
          case 'hidden':
            visible.value = false;
            await tester.pump();
          case 'background-wake':
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
          case 'covered':
            navigator.currentState!.push(
              CupertinoPageRoute<void>(
                builder: (_) => const Center(child: Text('Covering route')),
              ),
            );
            await tester.pumpAndSettle();
          case 'reparent':
            final other = AppInteractionController();
            addTearDown(other.dispose);
            await mount(
              tester,
              tile,
              interaction: other,
              visible: visible,
              navigator: navigator,
            );
          case 'disposed':
            await tester.pumpWidget(const SizedBox.shrink());
        }
        captured();
        await tester.pumpAndSettle();
        expect(routes, 0);
        expect(find.text('Service destination'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'disabled whole-card actions stay out of keyboard and semantics activation',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await mount(
          tester,
          (_) => const SizedBox(
            width: 164,
            height: 128,
            child: DashboardTileButton(
              label: 'Unavailable card',
              onPressed: null,
              child: Text('Unavailable card'),
            ),
          ),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        final node = buttons(tester).single;
        expect(node.label, 'Unavailable card');
        expect(
          node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
          isFalse,
        );
        expect(
          node.getSemanticsData().hasAction(ui.SemanticsAction.longPress),
          isFalse,
        );
        expect(
          tester.widget<CupertinoButton>(find.byType(CupertinoButton)).enabled,
          isFalse,
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'busy accessory ignores duplicate keyboard and screen-reader commands',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final entities = _Entities()..pending = Completer<void>();
      try {
        await mount(
          tester,
          (context) => SizedBox(
            width: 180,
            height: HomeAccessoryTile.heightFor(context),
            child: HomeAccessoryTile(
              entity: const HaEntity(entityId: 'light.desk', state: 'on'),
            ),
          ),
          entities: entities,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        final node = buttons(tester).single;
        node.owner!.performAction(node.id, ui.SemanticsAction.tap);
        expect(entities.calls, 1);
        entities.pending!.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'native card focus outline has contrast and remains inside grid clip ($brightness)',
      (tester) async {
        late Color surface;
        await mount(
          tester,
          (context) {
            surface = CupertinoColors.secondarySystemGroupedBackground
                .resolveFrom(context);
            return ClipRRect(
              key: const ValueKey('tile-clip'),
              borderRadius: BorderRadius.circular(22),
              child: SizedBox(
                width: 164,
                height: dashboardServiceRowExtent(context),
                child: ServiceTileShell(
                  icon: CupertinoIcons.wifi,
                  title: 'Keenetic',
                  connected: true,
                  onTap: () {},
                  lines: const ['3 devices online'],
                ),
              ),
            );
          },
          brightness: brightness,
          scale: 2,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final button = find.byType(CupertinoButton);
        final outline = find.descendant(
          of: button,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is ShapeDecoration &&
                (widget.decoration as ShapeDecoration).shape
                    is OutlinedBorder &&
                ((widget.decoration as ShapeDecoration).shape as OutlinedBorder)
                        .side
                        .width >
                    0,
          ),
        );
        expect(outline, findsOneWidget);
        final side =
            (tester.widget<DecoratedBox>(outline).decoration as ShapeDecoration)
                    .shape
                as OutlinedBorder;
        final a = side.side.color.computeLuminance(),
            b = surface.computeLuminance();
        final contrast =
            (a > b ? a + .05 : b + .05) / (a > b ? b + .05 : a + .05);
        expect(contrast, greaterThanOrEqualTo(3));
        final rect = tester.getRect(button),
            clip = tester.getRect(find.byKey(const ValueKey('tile-clip')));
        expect(clip.contains(rect.inflate(side.side.width).topLeft), isTrue);
        expect(
          clip.contains(rect.inflate(side.side.width).bottomRight),
          isTrue,
        );
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'accessory menu is reachable with the standard context-menu key',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final entities = _Entities();
      await mount(
        tester,
        (context) => SizedBox(
          width: 180,
          height: HomeAccessoryTile.heightFor(context),
          child: HomeAccessoryTile(
            entity: const HaEntity(
              entityId: 'light.desk',
              state: 'on',
              attributes: {'friendly_name': 'Desk'},
            ),
          ),
        ),
        entities: entities,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      for (final key in [
        LogicalKeyboardKey.contextMenu,
        LogicalKeyboardKey.f10,
      ]) {
        if (key == LogicalKeyboardKey.f10)
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(key);
        if (key == LogicalKeyboardKey.f10)
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(find.byType(CupertinoActionSheet), findsOneWidget);
        expect(entities.calls, 0);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
    },
  );
  for (final language in ['en', 'tr']) {
    testWidgets('service tile is one named keyboard button ($language)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        var calls = 0;
        final summary = language == 'en'
            ? '3 devices online'
            : '3 cihaz çevrimiçi';
        await mount(
          tester,
          (context) => SizedBox(
            width: 180,
            height: dashboardServiceRowExtent(context),
            child: ServiceTileShell(
              icon: CupertinoIcons.wifi,
              title: 'Keenetic',
              connected: true,
              onTap: () => calls++,
              lines: [summary],
            ),
          ),
          language: language,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(calls, 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(calls, 2);
        expect(buttons(tester), hasLength(1));
        final node = buttons(tester).single;
        expect(node.label, 'Keenetic, $summary');
        expect(
          node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
          isTrue,
        );
        node.owner!.performAction(node.id, ui.SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(calls, 3);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets(
      'accessory tile keyboard uses guarded action and one state label ($language)',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final entities = _Entities();
          await mount(
            tester,
            (context) => SizedBox(
              width: 180,
              height: HomeAccessoryTile.heightFor(context),
              child: HomeAccessoryTile(
                entity: const HaEntity(
                  entityId: 'light.desk',
                  state: 'on',
                  attributes: {'friendly_name': 'Desk'},
                ),
              ),
            ),
            entities: entities,
            language: language,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(entities.calls, 1);
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pumpAndSettle();
          expect(entities.calls, 2);
          expect(buttons(tester), hasLength(1));
          expect(
            buttons(tester).single.label,
            'Desk, ${language == 'en' ? 'On' : 'Açık'}',
          );
        } finally {
          semantics.dispose();
        }
      },
    );

    for (final brightness in Brightness.values) {
      testWidgets(
        'shared tiles fit narrow cells at 2x ($language $brightness)',
        (tester) async {
          await mount(
            tester,
            (context) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 164,
                  height: HomeAccessoryTile.heightFor(context),
                  child: HomeAccessoryTile(
                    entity: HaEntity(
                      entityId: 'light.desk',
                      state: 'off',
                      attributes: {
                        'friendly_name': language == 'en'
                            ? 'Living room reading lamp'
                            : 'Oturma odası okuma lambası',
                      },
                    ),
                  ),
                ),
                SizedBox(
                  width: 164,
                  height: dashboardServiceRowExtent(context),
                  child: ServiceTileShell(
                    icon: CupertinoIcons.wifi,
                    title: 'Music Assistant',
                    connected: true,
                    onTap: () {},
                    lines: const [
                      'Living room HomePod',
                      'A long playback status line',
                      '3 devices online',
                    ],
                  ),
                ),
              ],
            ),
            language: language,
            brightness: brightness,
            scale: 2,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
