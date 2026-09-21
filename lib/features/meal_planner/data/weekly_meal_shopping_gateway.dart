import '../../today/data/today_actions.dart';
import '../../today/domain/today_models.dart';
import '../domain/recipe_shopping_draft.dart';
import '../domain/weekly_meal_plan.dart';
import 'recipe_shopping_handoff.dart';

abstract interface class WeeklyMealShoppingGateway {
  String get listTitle;

  Future<int> add({
    required WeeklyMealPlan plan,
    required MealPlanEntry entry,
    required String locale,
    required bool Function() visible,
  });
}

final class VerifiedWeeklyMealShoppingGateway
    implements WeeklyMealShoppingGateway {
  const VerifiedWeeklyMealShoppingGateway({
    required this.list,
    required this.actions,
    required this.authoritySource,
    required this.listCurrent,
  });

  final TodayTodoList list;
  final TodayActions actions;
  final RecipeShoppingAuthoritySource authoritySource;
  final bool Function() listCurrent;

  @override
  String get listTitle => list.title;

  @override
  Future<int> add({
    required WeeklyMealPlan plan,
    required MealPlanEntry entry,
    required String locale,
    required bool Function() visible,
  }) async {
    if (!listCurrent()) {
      throw const RecipeShoppingException('list_unavailable');
    }
    final authority = RecipeShoppingAuthorityLease.capture(authoritySource);
    if (authority == null) {
      throw const RecipeShoppingException('stale_authority');
    }
    final receipt = await RecipeShoppingHandoff().addPlanEntry(
      plan: plan,
      entryId: entry.id,
      locale: locale,
      list: list,
      actions: actions,
      authority: authority,
      authoritySource: authoritySource,
      visible: () => visible() && listCurrent(),
    );
    if (!visible() || !listCurrent()) {
      throw RecipeShoppingException(
        'stale_authority',
        completedCount: receipt.verifiedCount,
      );
    }
    return receipt.verifiedCount;
  }
}
