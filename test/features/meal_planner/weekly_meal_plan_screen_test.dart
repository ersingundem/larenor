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

WeeklyMealPlanSnapshot snapshot() => WeeklyMealPlanSnapshot.fromJson(
  {
    'authority': {
      'schemaVersion': 1,
      'coreId': core,
      'homeId': home,
      'accountId': account,
      'sessionFamilyId': family,
      'accountRevision': 3,
      'planRevision': 2,
    },
    'plan': {
      'schemaVersion': 1,
      'revision': 2,
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
          'servings': 4,
          'personId': person,
          'expectedPersonRevision': 7,
          'expectedPersonAclRevision': 9,
        },
      ],
    },
  },
  ServerContext.fromJson({'schemaVersion': 1, 'coreId': core, 'homeId': home}),
);

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
          await tester.ensureVisible(preview);
          expect(tester.getSize(preview).height, greaterThanOrEqualTo(48));
          await tester.tap(preview);
          await tester.pumpAndSettle();
          expect(find.textContaining('200 g Mercimek'), findsOneWidget);
        },
      );
    }
  }

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
}
