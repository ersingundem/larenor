import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/dashboard/presentation/dashboard_card_presentation.dart';
import 'package:larenor/features/dashboard/presentation/tiles/home_accessory_tile.dart';
import 'package:larenor/features/dashboard/presentation/tiles/service_tile_shell.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Entities extends Entities {
  int calls = 0;
  Completer<void>? pending;
  @override
  Future<Map<String, HaEntity>> build() async => {};
  @override
  Future<void> toggle(HaEntity entity) async {
    calls++;
    await pending?.future;
  }
}

Future<void> mount(WidgetTester tester, WidgetBuilder child, {
  String language = 'en',
  Brightness brightness = Brightness.light,
  double scale = 1,
  _Entities? entities,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      wellbeingPrivateEntityIdsProvider.overrideWithValue(const AsyncData({})),
      if (entities != null) entitiesProvider.overrideWith(() => entities),
    ],
    child: CupertinoApp(
      theme: larenorTheme(brightness: brightness),
      locale: Locale(language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: CupertinoPageScaffold(child: Center(child: Builder(builder: child))),
    ),
  ));
  await tester.pumpAndSettle();
}

List<SemanticsNode> buttons(WidgetTester tester) {
  final result = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    if (node.getSemanticsData().flagsCollection.isButton) result.add(node);
    node.visitChildren((child) { visit(child); return true; });
  }
  visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return result;
}

void main() {
  for (final language in ['en', 'tr']) {
    testWidgets('service tile is one named keyboard button ($language)', (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(semantics.dispose);
      var calls = 0;
      final summary = language == 'en' ? '3 devices online' : '3 cihaz çevrimiçi';
      await mount(tester, (context) => SizedBox(
        width: 180, height: dashboardServiceRowExtent(context),
        child: ServiceTileShell(icon: CupertinoIcons.wifi, title: 'Keenetic',
          connected: true, onTap: () => calls++, lines: [summary]),
      ), language: language);
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
      expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
      node.owner!.performAction(node.id, ui.SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(calls, 3);
    });

    testWidgets('accessory tile keyboard uses guarded action and one state label ($language)', (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(semantics.dispose);
      final entities = _Entities();
      await mount(tester, (context) => SizedBox(
        width: 180, height: HomeAccessoryTile.heightFor(context),
        child: HomeAccessoryTile(entity: const HaEntity(entityId: 'light.desk', state: 'on',
          attributes: {'friendly_name': 'Desk'})),
      ), entities: entities, language: language);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(entities.calls, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(entities.calls, 2);
      expect(buttons(tester), hasLength(1));
      expect(buttons(tester).single.label, 'Desk, ${language == 'en' ? 'On' : 'Açık'}');
    });

    for (final brightness in Brightness.values) {
      testWidgets('shared tiles fit narrow cells at 2x ($language $brightness)', (tester) async {
        await mount(tester, (context) => Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 164, height: HomeAccessoryTile.heightFor(context),
            child: HomeAccessoryTile(entity: HaEntity(entityId: 'light.desk', state: 'off', attributes: {
              'friendly_name': language == 'en' ? 'Living room reading lamp' : 'Oturma odası okuma lambası',
            }))),
          SizedBox(width: 164, height: dashboardServiceRowExtent(context),
            child: ServiceTileShell(icon: CupertinoIcons.wifi, title: 'Music Assistant', connected: true,
              onTap: () {}, lines: const ['Living room HomePod', 'A long playback status line', '3 devices online'])),
        ]), language: language, brightness: brightness, scale: 2);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
