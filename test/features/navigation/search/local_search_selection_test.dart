import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/navigation/search/domain/local_search_index.dart';
import 'package:larenor/features/navigation/search/domain/navigation_target.dart';
import 'package:larenor/features/navigation/search/presentation/local_search_screen.dart';
import 'package:larenor/features/navigation/search/providers/local_search_providers.dart';
import 'package:larenor/features/settings/data/app_service.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Index extends LocalSearchIndexController {
  _Index(this.index);
  final LocalSearchIndex index;
  @override
  LocalSearchIndex build() => index;
}

LocalSearchIndex _index() => LocalSearchIndex.build(
  homeSource: LocalSearchSource.core,
  homeAvailability: LocalSearchAvailability.stale,
  rooms: [
    const DashboardRoom(
      id: 'living',
      name: 'Salon',
      entityIds: ['light.living', 'scene.cinema'],
    ),
  ],
  entities: [
    const LocalSearchEntity(entityId: 'light.living', name: 'Salon ışığı'),
    const LocalSearchEntity(entityId: 'scene.cinema', name: 'Sinema sahnesi'),
  ],
  systems: [
    const LocalSearchSystem(
      service: AppService.proxmox,
      source: LocalSearchSource.direct,
      availability: LocalSearchAvailability.offline,
    ),
  ],
);

Future<void> _mount(
  WidgetTester tester,
  ProviderContainer container,
  List<NavigationTarget> opened, {
  Size size = const Size(600, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => CupertinoPageScaffold(
            child: CupertinoButton(
              child: const Text('Open search'),
              onPressed: () => Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (_) => LocalSearchScreen(
                    autofocus: true,
                    onOpenTarget: (target) {
                      opened.add(target);
                      Navigator.pop(context);
                    },
                    onOpenRemoteMedia: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open search'));
  await tester.pumpAndSettle();
}

void main() {
  test('one index distinguishes Core, Direct, stale and offline targets', () {
    final index = _index();
    final room = index.search('salon').first;
    final light = index.search('salon ışığı').single;
    final scene = index.search('sinema').single;
    final proxmox = index.search('proxmox').single;
    expect(room.kind, LocalSearchKind.room);
    expect(light.kind, LocalSearchKind.entity);
    expect(scene.kind, LocalSearchKind.scene);
    expect(light.source, LocalSearchSource.core);
    expect(light.availability, LocalSearchAvailability.stale);
    expect(proxmox.kind, LocalSearchKind.system);
    expect(proxmox.source, LocalSearchSource.direct);
    expect(proxmox.availability, LocalSearchAvailability.offline);
  });

  for (final size in [const Size(600, 900), const Size(1280, 900)]) {
    testWidgets('selection persists across screens at ${size.width} and 2x', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      final opened = <NavigationTarget>[];
      final container = ProviderContainer(
        overrides: [
          localSearchIndexProvider.overrideWith(() => _Index(_index())),
        ],
      );
      addTearDown(container.dispose);
      await _mount(tester, container, opened, size: size);
      await tester.enterText(find.byType(CupertinoSearchTextField), 'salon');
      await tester.pump(const Duration(milliseconds: 151));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        container.read(localSearchSelectionProvider).selectedId,
        'room:living',
      );
      final semantics = tester.ensureSemantics();
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('room:living')))
            .flagsCollection
            .isSelected,
        ui.Tristate.isTrue,
      );
      semantics.dispose();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(opened, [const RoomNavigationTarget('living')]);
      await tester.tap(find.text('Open search'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CupertinoSearchTextField>(
              find.byType(CupertinoSearchTextField),
            )
            .controller!
            .text,
        'salon',
      );
      expect(find.byKey(const ValueKey('room:living')), findsOneWidget);
      expect(find.textContaining('Core'), findsWidgets);
      expect(find.textContaining('Stale'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Direct offline infrastructure remains visible and read-only', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        localSearchIndexProvider.overrideWith(() => _Index(_index())),
      ],
    );
    addTearDown(container.dispose);
    await _mount(tester, container, []);
    await tester.enterText(find.byType(CupertinoSearchTextField), 'proxmox');
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();
    expect(find.byKey(const ValueKey('system:proxmox')), findsOneWidget);
    expect(find.textContaining('Direct'), findsOneWidget);
    expect(find.textContaining('Offline'), findsOneWidget);
  });
}
