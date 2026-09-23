import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/meal_planner/data/recipe_shopping_handoff.dart';
import 'package:larenor/features/meal_planner/data/weekly_meal_plan_api.dart';
import 'package:larenor/features/meal_planner/domain/weekly_meal_plan.dart';
import 'package:larenor/features/meal_planner/presentation/weekly_meal_plan_screen.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/today/data/today_actions.dart';
import 'package:larenor/features/today/domain/today_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const core = '1a111111111111111111111111111111';
const home = '2b222222222222222222222222222222';
const account = '3c333333333333333333333333333333';
const family = '4d444444444444444444444444444444';
const person = '5e555555555555555555555555555555';
const recipe = '6f666666666666666666666666666666';
const entry = '7a777777777777777777777777777777';

class ShoppingSource implements RecipeShoppingAuthoritySource {
  RecipeShoppingAuthorityFacts? facts = RecipeShoppingAuthorityFacts.core(
    coreId: core,
    homeId: home,
    accountId: account,
    sessionFamily: 1,
    endpointBaseUrl: 'https://core.invalid',
    runtimeIdentity: Object(),
    interactionEpoch: 1,
  );

  @override
  RecipeShoppingAuthorityFacts? read() => facts;
}

class ShoppingActions implements TodayActions {
  final calls = <({String list, String summary})>[];
  Completer<void>? first;

  @override
  Future<void> addTodoBound(
    TodayTodoList list,
    String summary, {
    required bool Function() current,
    String? idempotencyKey,
    String? dueDate,
    DateTime? dueAt,
    String? description,
  }) async {
    if (!current()) throw StateError('stale');
    calls.add((list: list.entityId, summary: summary));
    if (calls.length == 1) await first?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const shopping = TodayTodoList(
  entityId: 'todo.shopping',
  title: 'Shopping',
  supportedFeatures: 65,
  available: true,
  items: TodayRead(value: []),
);

const familyShopping = TodayTodoList(
  entityId: 'todo.family_shopping',
  title: 'Family shopping',
  supportedFeatures: 65,
  available: true,
  items: TodayRead(value: []),
);

WeeklyMealPlanSnapshot snapshot({
  int revision = 2,
  int servings = 4,
  bool extraIngredient = false,
}) => WeeklyMealPlanSnapshot.fromJson(
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
            if (extraIngredient)
              {
                'schemaVersion': 1,
                'quantityMillis': 1000,
                'unit': 'piece',
                'name': 'Limon',
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
  ServerContext.fromJson({'schemaVersion': 1, 'coreId': core, 'homeId': home}),
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
  List<TodayTodoList> shoppingLists = const [],
  TodayActions? shoppingActions,
  RecipeShoppingAuthoritySource? shoppingAuthoritySource,
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
      home: WeeklyMealPlanScreen(
        gateway: gateway,
        isCurrent: current,
        shoppingLists: shoppingLists,
        shoppingActions: shoppingActions,
        shoppingAuthoritySource: shoppingAuthoritySource,
      ),
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
          expect(
            find.byKey(const ValueKey('meal-shopping-unavailable')),
            findsOneWidget,
          );
        },
      );
    }
  }

  testWidgets(
    'edits slot and servings through exact optimistic revision save',
    (tester) async {
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
      await tester.tap(find.byKey(const ValueKey('meal-edit-slot-lunch')));
      expect(
        tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('meal-edit-save')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('meal-edit-save')));
      await tester.pumpAndSettle();

      expect(find.text('Mercimek çorbası'), findsOneWidget);
      expect(gateway.base!.authority.planRevision, 2);
      expect(gateway.requestId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(gateway.recipes!.single.title, 'Mercimek çorbası');
      expect(gateway.entries!.single.servings, 6);
      expect(gateway.entries!.single.slot, MealSlot.lunch);
      expect(find.textContaining('6 servings'), findsOneWidget);
    },
  );

  testWidgets('selected writable HA list requires explicit confirmation', (
    tester,
  ) async {
    final source = ShoppingSource(), actions = ShoppingActions();
    await mount(
      tester,
      locale: const Locale('en'),
      width: 600,
      gateway: FakeGateway(Future.value(snapshot())),
      current: () => true,
      shoppingLists: const [shopping, familyShopping],
      shoppingActions: actions,
      shoppingAuthoritySource: source,
    );
    final preview = find.byKey(const ValueKey('meal-shopping-$entry'));
    await tester.ensureVisible(preview);
    await tester.tap(preview);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('meal-shopping-list-todo.family_shopping')),
    );
    await tester.tap(find.byKey(const ValueKey('meal-shopping-review')));
    await tester.pumpAndSettle();
    expect(actions.calls, isEmpty);

    await tester.tap(find.byKey(const ValueKey('meal-shopping-confirm')));
    await tester.pumpAndSettle();

    expect(actions.calls, [
      (list: 'todo.family_shopping', summary: '200 g Mercimek'),
    ]);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 1000));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('meal-shopping-success')), findsOneWidget);
  });

  testWidgets('backgrounded late HA readback cannot publish or continue', (
    tester,
  ) async {
    final source = ShoppingSource();
    final actions = ShoppingActions()..first = Completer<void>();
    await mount(
      tester,
      locale: const Locale('tr'),
      width: 600,
      gateway: FakeGateway(Future.value(snapshot(extraIngredient: true))),
      current: () => true,
      shoppingLists: const [shopping],
      shoppingActions: actions,
      shoppingAuthoritySource: source,
    );
    final preview = find.byKey(const ValueKey('meal-shopping-$entry'));
    await tester.ensureVisible(preview);
    await tester.tap(preview);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -320));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('meal-shopping-review')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('meal-shopping-confirm')));
    for (var frame = 0; frame < 10 && actions.calls.isEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(actions.calls, hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    actions.first!.complete();
    await tester.pump();

    expect(actions.calls, hasLength(1));
    expect(find.byKey(const ValueKey('meal-shopping-success')), findsNothing);
  });

  testWidgets(
    'confirmation opened before retirement cannot start after resume',
    (tester) async {
      final source = ShoppingSource(), actions = ShoppingActions();
      await mount(
        tester,
        locale: const Locale('en'),
        width: 600,
        gateway: FakeGateway(Future.value(snapshot())),
        current: () => true,
        shoppingLists: const [shopping],
        shoppingActions: actions,
        shoppingAuthoritySource: source,
      );
      final preview = find.byKey(const ValueKey('meal-shopping-$entry'));
      await tester.ensureVisible(preview);
      await tester.tap(preview);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).last, const Offset(0, -240));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('meal-shopping-review')));
      await tester.pumpAndSettle();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('meal-shopping-confirm')));
      await tester.pumpAndSettle();

      expect(actions.calls, isEmpty);
      expect(find.byKey(const ValueKey('meal-shopping-success')), findsNothing);
    },
  );

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
    tester
        .widget<CupertinoButton>(find.byKey(const ValueKey('meal-edit-save')))
        .onPressed!();
    for (var frame = 0; frame < 10 && gateway.base == null; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(gateway.base, isNotNull);
    authorityThrows = true;
    delayed.complete(snapshot(revision: 3, servings: 6));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('6 servings'), findsNothing);
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
