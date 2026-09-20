import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/meal_planner/domain/recipe_shopping_draft.dart';

void main() {
  test('parses bounded units and scales exact shopping summaries', () {
    final draft = RecipeShoppingDraft.parse(
      title: 'Mercimek çorbası',
      baseServingsText: '2',
      targetServingsText: '5',
      ingredientLines: '200 g Mercimek\n1,5 l Su\n2 adet Havuç',
    );

    expect(draft.shoppingSummaries('tr'), [
      '500 g Mercimek',
      '3,75 l Su',
      '5 adet Havuç',
    ]);
    expect(draft.shoppingSummaries('en').last, '5 pcs Havuç');
    expect(draft.toString(), 'RecipeShoppingDraft(servings: 2->5, items: 3)');
  });

  test('rejects unbounded, ambiguous and control-character input', () {
    for (final lines in [
      'Salt',
      '1 spoon Salt',
      '0 g Salt',
      '1 g Bad\u0000name',
      List.filled(33, '1 g Salt').join('\n'),
    ]) {
      expect(
        () => RecipeShoppingDraft.parse(
          title: 'Recipe',
          baseServingsText: '2',
          targetServingsText: '4',
          ingredientLines: lines,
        ),
        throwsA(isA<RecipeShoppingException>()),
      );
    }
    expect(
      () => RecipeShoppingDraft.parse(
        title: 'Recipe',
        baseServingsText: '0',
        targetServingsText: '25',
        ingredientLines: '1 kg Potato',
      ),
      throwsA(isA<RecipeShoppingException>()),
    );
  });
}
