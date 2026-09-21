import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/meal_planner/data/recipe_shopping_handoff.dart';
import 'package:larenor/features/meal_planner/data/weekly_meal_shopping_gateway.dart';
import 'package:larenor/features/meal_planner/domain/recipe_shopping_draft.dart';
import 'package:larenor/features/meal_planner/domain/weekly_meal_plan.dart';
import 'package:larenor/features/today/data/today_actions.dart';
import 'package:larenor/features/today/domain/today_models.dart';

class _Source implements RecipeShoppingAuthoritySource {
  RecipeShoppingAuthorityFacts? facts;
  @override
  RecipeShoppingAuthorityFacts? read() => facts;
}

class _Actions implements TodayActions {
  final calls = <String>[];
  final keys = <String?>[];
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
    calls.add(summary);
    keys.add(idempotencyKey);
    if (calls.length == 1) await first?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _list = TodayTodoList(
  entityId: 'todo.shopping_list',
  title: 'Shopping',
  supportedFeatures: 1,
  available: true,
  items: TodayRead(value: []),
);

RecipeShoppingAuthorityFacts _facts({
  String home = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  int family = 7,
}) => RecipeShoppingAuthorityFacts.core(
  coreId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  homeId: home,
  accountId: 'cccccccccccccccccccccccccccccccc',
  sessionFamily: family,
  endpointBaseUrl: 'https://core.invalid',
  runtimeIdentity: 'runtime-a',
  interactionEpoch: 3,
);

RecipeShoppingDraft _draft() => RecipeShoppingDraft.parse(
  title: 'Soup',
  baseServingsText: '2',
  targetServingsText: '4',
  ingredientLines: '100 g Lentils\n1 l Water',
);

WeeklyMealPlan _plan() => WeeklyMealPlan.fromJson({
  'schemaVersion': 1,
  'revision': 1,
  'weekStart': '2026-09-21',
  'recipes': [
    {
      'schemaVersion': 1,
      'id': '1' * 32,
      'locale': 'tr',
      'title': 'Çorba',
      'baseServings': 2,
      'ingredients': [
        {
          'schemaVersion': 1,
          'quantityMillis': 1000,
          'unit': 'piece',
          'name': 'Mercimek',
        },
      ],
    },
  ],
  'entries': [
    {
      'schemaVersion': 1,
      'id': '2' * 32,
      'date': '2026-09-21',
      'slot': 'dinner',
      'recipeId': '1' * 32,
      'servings': 4,
      'personId': '3' * 32,
      'expectedPersonRevision': 1,
      'expectedPersonAclRevision': 1,
    },
  ],
});

void main() {
  test('requires exact Core home account and session-family authority', () {
    final source = _Source()..facts = _facts();
    final lease = RecipeShoppingAuthorityLease.capture(source)!;
    expect(lease.isCurrent(source), isTrue);

    for (final changed in [
      _facts(home: 'dddddddddddddddddddddddddddddddd'),
      _facts(family: 8),
      _facts().copyWith(accountId: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'),
      _facts().copyWith(coreId: 'ffffffffffffffffffffffffffffffff'),
      _facts().copyWith(interactionEpoch: 4),
    ]) {
      source.facts = changed;
      expect(lease.isCurrent(source), isFalse);
    }
    expect(lease.toString(), 'RecipeShoppingAuthorityLease(core)');
  });

  test(
    'verified handoff sends each item once and returns exact count',
    () async {
      final source = _Source()..facts = _facts();
      final actions = _Actions();
      final result = await RecipeShoppingHandoff().add(
        draft: _draft(),
        locale: 'en',
        list: _list,
        actions: actions,
        authority: RecipeShoppingAuthorityLease.capture(source)!,
        authoritySource: source,
        visible: () => true,
      );

      expect(actions.calls, ['200 g Lentils', '2 l Water']);
      expect(result.verifiedCount, 2);
      expect(result.toString(), 'RecipeShoppingReceipt(verified: 2)');
    },
  );

  test(
    'Core menu entry scales portions and keeps one stable retry key',
    () async {
      final source = _Source()..facts = _facts();
      final actions = _Actions();
      final handoff = RecipeShoppingHandoff();
      final lease = RecipeShoppingAuthorityLease.capture(source)!;
      final plan = _plan();
      for (var attempt = 0; attempt < 2; attempt++) {
        await handoff.addPlanEntry(
          plan: plan,
          entryId: '2' * 32,
          locale: attempt == 0 ? 'tr' : 'en',
          list: _list,
          actions: actions,
          authority: lease,
          authoritySource: source,
          visible: () => true,
        );
      }
      expect(actions.calls, ['2 adet Mercimek', '2 pcs Mercimek']);
      expect(actions.keys[0], actions.keys[1]);
      expect(actions.keys.every((value) => value?.length == 64), isTrue);
    },
  );

  test(
    'late authority change stops remaining writes and fails closed',
    () async {
      final source = _Source()..facts = _facts();
      final actions = _Actions()..first = Completer<void>();
      final future = RecipeShoppingHandoff().add(
        draft: _draft(),
        locale: 'en',
        list: _list,
        actions: actions,
        authority: RecipeShoppingAuthorityLease.capture(source)!,
        authoritySource: source,
        visible: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      source.facts = _facts(family: 8);
      actions.first!.complete();

      await expectLater(
        future,
        throwsA(
          isA<RecipeShoppingException>()
              .having((e) => e.code, 'code', 'stale_authority')
              .having((e) => e.completedCount, 'completedCount', 1),
        ),
      );
      expect(actions.calls, ['200 g Lentils']);
    },
  );

  test('hidden route and unavailable list never start a write', () async {
    final source = _Source()..facts = _facts();
    final actions = _Actions();
    final lease = RecipeShoppingAuthorityLease.capture(source)!;
    await expectLater(
      RecipeShoppingHandoff().add(
        draft: _draft(),
        locale: 'en',
        list: _list,
        actions: actions,
        authority: lease,
        authoritySource: source,
        visible: () => false,
      ),
      throwsA(isA<RecipeShoppingException>()),
    );
    expect(actions.calls, isEmpty);
  });

  test(
    'weekly gateway rechecks the exact writable list during handoff',
    () async {
      final source = _Source()..facts = _facts();
      final actions = _Actions()..first = Completer<void>();
      var listCurrent = true;
      final plan = _plan();
      final future =
          VerifiedWeeklyMealShoppingGateway(
            list: _list,
            actions: actions,
            authoritySource: source,
            listCurrent: () => listCurrent,
          ).add(
            plan: plan,
            entry: plan.entries.single,
            locale: 'tr',
            visible: () => true,
          );
      await Future<void>.delayed(Duration.zero);
      listCurrent = false;
      actions.first!.complete();

      await expectLater(
        future,
        throwsA(
          isA<RecipeShoppingException>()
              .having((error) => error.code, 'code', 'stale_authority')
              .having((error) => error.completedCount, 'completedCount', 1),
        ),
      );
      expect(actions.calls, ['2 adet Mercimek']);
    },
  );
}
