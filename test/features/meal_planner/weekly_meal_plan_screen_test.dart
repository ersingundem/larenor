import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/meal_planner/data/weekly_meal_plan_api.dart';
import 'package:larenor/features/meal_planner/domain/weekly_meal_plan.dart';
import 'package:larenor/features/meal_planner/presentation/weekly_meal_plan_screen.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const core = '1a111111111111111111111111111111';
const home = '2b222222222222222222222222222222';
const account = '3c333333333333333333333333333333';
const family = '4d444444444444444444444444444444';
const person = '5e555555555555555555555555555555';
const recipe = '6f666666666666666666666666666666';
const entry = '7a777777777777777777777777777777';

WeeklyMealPlanSnapshot snapshot({int revision = 2, int servings = 4}) =>
    WeeklyMealPlanSnapshot.fromJson(
      {
        'authority': {
          'schemaVersion': 1,
          'coreId': core,
          'homeId': home,
          'accountId': account,
          'sessionFamilyId': family,
          'accountRevision': 3,
          'planRevision': revision,
        },
        'plan': {
          'schemaVersion': 1,
          'revision': revision,
          'weekStart': '2026-09-21',
          'recipes': [
            {
              'schemaVersion': 1,
              'id': recipe,
              'locale': 'tr',
              'title': 'Mercimek çorbası',
              'baseServings': 2,
              'ingredients': [
                {
                  'schemaVersion': 1,
                  'quantityMillis': 100000,
                  'unit': 'g',
                  'name': 'Mercimek',
                },
              ],
            },
          ],
          'entries': [
            {
              'schemaVersion': 1,
              'id': entry,
              'date': '2026-09-21',
              'slot': 'dinner',
              'recipeId': recipe,
              'servings': servings,
              'personId': person,
              'expectedPersonRevision': 7,
              'expectedPersonAclRevision': 9,
            },
          ],
        },
      },
      ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': core,
        'homeId': home,
      }),
    );

final class SavingGateway implements WeeklyMealPlanGateway {
  SavingGateway({this.saveResult});

  final Completer<WeeklyMealPlanSnapshot>? saveResult;
  WeeklyMealPlanSnapshot? base;
  String? requestId;
  List<MealRecipe>? recipes;
  List<MealPlanEntry>? entries;

  @override
  Future<WeeklyMealPlanSnapshot> read() async => snapshot();

  @override
  Future<WeeklyMealPlanSnapshot> save({
    required WeeklyMealPlanSnapshot base,
    required String requestId,
    required String weekStart,
    required List<MealRecipe> recipes,
    required List<MealPlanEntry> entries,
  }) {
    this.base = base;
    this.requestId = requestId;
    this.recipes = recipes;
    this.entries = entries;
    return saveResult?.future ??
        Future.value(snapshot(revision: 3, servings: entries.single.servings));
  }
}

final class FakeGateway implements WeeklyMealPlanGateway {
  FakeGateway(this.readFuture);

  final Future<WeeklyMealPlanSnapshot> readFuture;

  @override
  Future<WeeklyMealPlanSnapshot> read() => readFuture;

  @override
  Future<WeeklyMealPlanSnapshot> save({
    required WeeklyMealPlanSnapshot base,
    required String requestId,
    required String weekStart,
    required List<MealRecipe> recipes,
    required List<MealPlanEntry> entries,
  }) => throw UnimplementedError();
}

final class RefreshGateway implements WeeklyMealPlanGateway {
  final secondRead = Completer<WeeklyMealPlanSnapshot>();
  int reads = 0;

  @override
  Future<WeeklyMealPlanSnapshot> read() {
    reads++;
    return reads == 1 ? Future.value(snapshot()) : secondRead.future;
  }

  @override
  Future<WeeklyMealPlanSnapshot> save({
    required WeeklyMealPlanSnapshot base,
    required String requestId,
    required String weekStart,
    required List<MealRecipe> recipes,
    required List<MealPlanEntry> entries,
  }) => throw UnimplementedError();
}

Future<void> mount(
  WidgetTester tester, {
  required Locale locale,
  required double width,
  required WeeklyMealPlanGateway gateway,
  required bool Function() current,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: WeeklyMealPlanScreen(gateway: gateway, isCurrent: current),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets(
        '${locale.languageCode} $width 2x shows a usable weekly menu',
        (tester) async {
          await mount(
            tester,
            locale: locale,
            width: width,
            gateway: FakeGateway(Future.value(snapshot())),
            current: () => true,
          );
          expect(tester.takeException(), isNull);
          expect(find.text('Mercimek çorbası'), findsOneWidget);
          final preview = find.byKey(const ValueKey('meal-shopping-$entry'));
          final edit = find.byKey(const ValueKey('meal-edit-$entry'));
          await tester.ensureVisible(preview);
          expect(tester.getSize(preview).height, greaterThanOrEqualTo(48));
          await tester.ensureVisible(edit);
          expect(tester.getSize(edit).height, greaterThanOrEqualTo(48));
          await tester.tap(preview);
          await tester.pumpAndSettle();
          expect(find.textContaining('200 g Mercimek'), findsOneWidget);
        },
      );
    }
  }

  testWidgets('edits servings through an exact optimistic revision save', (
    tester,
  ) async {
    final gateway = SavingGateway();
    await mount(
      tester,
      locale: const Locale('en'),
      width: 600,
      gateway: gateway,
      current: () => true,
    );
    final edit = find.byKey(const ValueKey('meal-edit-$entry'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('meal-edit-servings')),
      '6',
    );
    await tester.tap(find.byKey(const ValueKey('meal-edit-save')));
    await tester.pumpAndSettle();

    expect(gateway.base!.authority.planRevision, 2);
    expect(gateway.requestId, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(gateway.recipes!.single.title, 'Mercimek çorbası');
    expect(gateway.entries!.single.servings, 6);
    expect(find.text('6 servings'), findsOneWidget);
  });

  testWidgets('throwing authority after save await publishes no old result', (
    tester,
  ) async {
    final delayed = Completer<WeeklyMealPlanSnapshot>();
    final gateway = SavingGateway(saveResult: delayed);
    var authorityThrows = false;
    await mount(
      tester,
      locale: const Locale('en'),
      width: 600,
      gateway: gateway,
      current: () {
        if (authorityThrows) throw StateError('private authority failure');
        return true;
      },
    );
    final edit = find.byKey(const ValueKey('meal-edit-$entry'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('meal-edit-servings')),
      '6',
    );
    await tester.tap(find.byKey(const ValueKey('meal-edit-save')));
    await tester.pump();
    authorityThrows = true;
    delayed.complete(snapshot(revision: 3, servings: 6));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('6 servings'), findsNothing);
    expect(find.text('Mercimek çorbası'), findsNothing);
  });

  testWidgets('late menu cannot publish after route authority retires', (
    tester,
  ) async {
    final result = Completer<WeeklyMealPlanSnapshot>();
    var current = true;
    await tester.pumpWidget(
      CupertinoApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: WeeklyMealPlanScreen(
          gateway: FakeGateway(result.future),
          isCurrent: () => current,
        ),
      ),
    );
    await tester.pump();
    current = false;
    result.complete(snapshot());
    await tester.pumpAndSettle();
    expect(find.text('Mercimek çorbası'), findsNothing);
  });

  testWidgets('inactive route clears an already loaded menu before reuse', (
    tester,
  ) async {
    final active = ValueNotifier(true);
    final gateway = RefreshGateway();
    addTearDown(active.dispose);
    await tester.pumpWidget(
      CupertinoApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (context, enabled, _) => TickerMode(
            enabled: enabled,
            child: WeeklyMealPlanScreen(
              gateway: gateway,
              isCurrent: () => true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mercimek çorbası'), findsOneWidget);
    active.value = false;
    await tester.pumpAndSettle();
    expect(find.text('Mercimek çorbası'), findsNothing);
    active.value = true;
    await tester.pump();
    expect(gateway.reads, 2);
    expect(find.text('Mercimek çorbası'), findsNothing);
    gateway.secondRead.complete(snapshot());
    await tester.pumpAndSettle();
    expect(find.text('Mercimek çorbası'), findsOneWidget);
  });
}
