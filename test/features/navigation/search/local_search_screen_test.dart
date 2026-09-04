import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/navigation/search/domain/local_search_index.dart';
import 'package:larenor/features/navigation/search/domain/navigation_target.dart';
import 'package:larenor/features/navigation/search/presentation/local_search_screen.dart';
import 'package:larenor/features/navigation/search/providers/local_search_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Index extends LocalSearchIndexController {
  _Index(this.index);
  final LocalSearchIndex index;
  @override
  LocalSearchIndex build() => index;
}

Widget _app(
  LocalSearchIndex index, {
  ValueChanged<NavigationTarget>? onOpen,
  VoidCallback? onRemote,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en'),
}) => ProviderScope(
  overrides: [localSearchIndexProvider.overrideWith(() => _Index(index))],
  child: CupertinoApp(
    theme: CupertinoThemeData(brightness: brightness),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: LocalSearchScreen(
      onOpenTarget: onOpen ?? (_) {},
      onOpenRemoteMedia: onRemote ?? () {},
    ),
  ),
);

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(CupertinoSearchTextField), query);
  await tester.pump(const Duration(milliseconds: 151));
  await tester.pump();
}

void main() {
  testWidgets(
    'latest debounced query wins; clear and disposal cancel pending work',
    (tester) async {
      final index = LocalSearchIndex.build(
        rooms: [
          const DashboardRoom(id: 'salon', name: 'Salon'),
          const DashboardRoom(id: 'mutfak', name: 'Mutfak'),
        ],
      );
      await tester.pumpWidget(_app(index));
      await tester.pump();
      await tester.enterText(find.byType(CupertinoSearchTextField), 'salon');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(CupertinoSearchTextField), 'mutfak');
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(const ValueKey('room:salon')), findsNothing);
      expect(find.byKey(const ValueKey('room:mutfak')), findsNothing);
      await tester.pump(const Duration(milliseconds: 91));
      await tester.pump();
      expect(find.byKey(const ValueKey('room:mutfak')), findsOneWidget);
      await tester.enterText(find.byType(CupertinoSearchTextField), 'salon');
      await tester.enterText(find.byType(CupertinoSearchTextField), '');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('room:salon')), findsNothing);
      expect(find.byKey(const ValueKey('room:mutfak')), findsNothing);
      await tester.enterText(find.byType(CupertinoSearchTextField), 'salon');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('scene and remote catalog taps request navigation only', (
    tester,
  ) async {
    final targets = <NavigationTarget>[];
    var remote = 0;
    final index = LocalSearchIndex.build(
      entities: [
        const LocalSearchEntity(entityId: 'scene.cinema', name: 'Cinema'),
      ],
    );
    await tester.pumpWidget(
      _app(index, onOpen: targets.add, onRemote: () => remote++),
    );
    await _search(tester, 'cinema');
    expect(targets, isEmpty);
    expect(remote, 0);
    await tester.tap(find.byKey(const ValueKey('entity:scene.cinema')));
    await tester.pump();
    expect(targets, [const EntityNavigationTarget('scene.cinema')]);
    expect(remote, 0);
    await tester.tap(find.text('Search media catalog'));
    await tester.pump();
    expect(remote, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('5000 matches mount only visible result rows', (tester) async {
    final index = LocalSearchIndex.build(
      entities: [
        for (var i = 0; i < 5000; i++)
          LocalSearchEntity(entityId: 'light.lamp_$i', name: 'Lamp $i'),
      ],
    );
    await tester.pumpWidget(_app(index));
    await _search(tester, 'lamp');
    final rows = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('entity:'),
    );
    expect(rows.evaluate().length, inExclusiveRange(0, 40));
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(rows.evaluate().length, inExclusiveRange(0, 40));
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 568), const Size(1366, 1024)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '${size.width.toInt()} wide $brightness wraps long results at 2x Turkish text',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final index = LocalSearchIndex.build(
            rooms: [
              const DashboardRoom(
                id: 'salon',
                name: 'Salonda çok uzun bir oda adı ve aydınlatma alanı',
                entityIds: ['light.detailed_identifier'],
              ),
            ],
            entities: [
              const LocalSearchEntity(
                entityId: 'light.detailed_identifier',
                name: 'Salonda çok uzun bir cihaz adı ve aydınlatma grubu',
              ),
            ],
          );
          await tester.pumpWidget(
            _app(
              index,
              textScale: 2,
              brightness: brightness,
              locale: const Locale('tr'),
            ),
          );
          await _search(tester, 'salon');
          expect(tester.takeException(), isNull);
          expect(find.byKey(const ValueKey('room:salon')), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'small phone retains usable results above a keyboard at 2x text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        _app(
          LocalSearchIndex.build(
            rooms: [const DashboardRoom(id: 'salon', name: 'Salon')],
          ),
          textScale: 2,
          locale: const Locale('tr'),
        ),
      );
      await _search(tester, 'salon');
      expect(tester.takeException(), isNull);
      final list = tester.getSize(find.byType(ListView));
      expect(list.height, greaterThan(40));
      expect(find.text('Medya kataloğunda ara'), findsOneWidget);
    },
  );

  testWidgets('empty passive cache explains how to load local content', (
    tester,
  ) async {
    await tester.pumpWidget(_app(LocalSearchIndex.empty));
    await tester.pump();
    expect(
      find.text('Open Home or Media to load content, then search here.'),
      findsOneWidget,
    );
    expect(find.text('Search media catalog'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
