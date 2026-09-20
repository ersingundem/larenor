import '../../server/domain/server_models.dart';
import 'recipe_shopping_draft.dart';

const _identityPattern = r'^[0-9a-f]{32}$';

String _identity(Object? value) {
  if (value is! String || !RegExp(_identityPattern).hasMatch(value)) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 0 || value > 0x7fffffffffffffff) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

int _positiveRevision(Object? value) {
  final revision = _revision(value);
  if (revision == 0) {
    throw const LarenorServerException('invalid_response');
  }
  return revision;
}

List<Object?> _list(Object? value, int maximum) {
  if (value is! List<Object?> || value.length > maximum) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

void _keys(Map<String, dynamic> value, Set<String> expected) {
  if (value.length != expected.length ||
      !value.keys.toSet().containsAll(expected)) {
    throw const LarenorServerException('invalid_response');
  }
}

enum MealUnit { g, kg, ml, l, piece }

enum MealSlot { breakfast, lunch, dinner, snack }

final class MealIngredient {
  const MealIngredient({
    required this.quantityMillis,
    required this.unit,
    required this.name,
  });

  factory MealIngredient.fromJson(Object? json) {
    final value = serverObject(json);
    _keys(value, const {'schemaVersion', 'quantityMillis', 'unit', 'name'});
    if (value['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final quantity = _revision(value['quantityMillis']);
    if (quantity < 1 || quantity > 10000000) {
      throw const LarenorServerException('invalid_response');
    }
    final unit = switch (value['unit']) {
      'g' => MealUnit.g,
      'kg' => MealUnit.kg,
      'ml' => MealUnit.ml,
      'l' => MealUnit.l,
      'piece' => MealUnit.piece,
      _ => throw const LarenorServerException('invalid_response'),
    };
    return MealIngredient(
      quantityMillis: quantity,
      unit: unit,
      name: serverText(value['name'], max: 120),
    );
  }

  final int quantityMillis;
  final MealUnit unit;
  final String name;

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'quantityMillis': quantityMillis,
    'unit': unit.name,
    'name': name,
  };
}

final class MealRecipe {
  const MealRecipe({
    required this.id,
    required this.locale,
    required this.title,
    required this.baseServings,
    required this.ingredients,
  });

  factory MealRecipe.fromJson(Object? json) {
    final value = serverObject(json);
    _keys(value, const {
      'schemaVersion',
      'id',
      'locale',
      'title',
      'baseServings',
      'ingredients',
    });
    if (value['schemaVersion'] != 1 ||
        value['locale'] != 'en' && value['locale'] != 'tr') {
      throw const LarenorServerException('invalid_response');
    }
    final servings = _revision(value['baseServings']);
    final ingredients = _list(
      value['ingredients'],
      32,
    ).map(MealIngredient.fromJson).toList(growable: false);
    if (servings < 1 || servings > 24 || ingredients.isEmpty) {
      throw const LarenorServerException('invalid_response');
    }
    return MealRecipe(
      id: _identity(value['id']),
      locale: value['locale'] as String,
      title: serverText(value['title'], max: 100),
      baseServings: servings,
      ingredients: List.unmodifiable(ingredients),
    );
  }

  final String id, locale, title;
  final int baseServings;
  final List<MealIngredient> ingredients;

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'locale': locale,
    'title': title,
    'baseServings': baseServings,
    'ingredients': ingredients.map((value) => value.toJson()).toList(),
  };

  RecipeShoppingDraft shoppingDraft(int targetServings) =>
      RecipeShoppingDraft.structured(
        title: title,
        baseServings: baseServings,
        targetServings: targetServings,
        ingredients: ingredients
            .map(
              (value) => RecipeIngredient.structured(
                quantityMillis: value.quantityMillis,
                unit: switch (value.unit) {
                  MealUnit.g => RecipeIngredientUnit.gram,
                  MealUnit.kg => RecipeIngredientUnit.kilogram,
                  MealUnit.ml => RecipeIngredientUnit.milliliter,
                  MealUnit.l => RecipeIngredientUnit.liter,
                  MealUnit.piece => RecipeIngredientUnit.piece,
                },
                name: value.name,
              ),
            )
            .toList(growable: false),
      );
}

final class MealPlanEntry {
  const MealPlanEntry({
    required this.id,
    required this.date,
    required this.slot,
    required this.recipeId,
    required this.servings,
    required this.personId,
    required this.personRevision,
    required this.personAclRevision,
  });

  factory MealPlanEntry.fromJson(Object? json) {
    final value = serverObject(json);
    _keys(value, const {
      'schemaVersion',
      'id',
      'date',
      'slot',
      'recipeId',
      'servings',
      'personId',
      'expectedPersonRevision',
      'expectedPersonAclRevision',
    });
    final date = DateTime.tryParse(
      value['date'] is String ? value['date'] as String : '',
    );
    final canonicalDate = value['date'];
    final servings = _revision(value['servings']);
    if (value['schemaVersion'] != 1 ||
        date == null ||
        date.isUtc ||
        date.hour != 0 ||
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}' !=
            canonicalDate ||
        servings < 1 ||
        servings > 24) {
      throw const LarenorServerException('invalid_response');
    }
    final slot = switch (value['slot']) {
      'breakfast' => MealSlot.breakfast,
      'lunch' => MealSlot.lunch,
      'dinner' => MealSlot.dinner,
      'snack' => MealSlot.snack,
      _ => throw const LarenorServerException('invalid_response'),
    };
    return MealPlanEntry(
      id: _identity(value['id']),
      date: canonicalDate as String,
      slot: slot,
      recipeId: _identity(value['recipeId']),
      servings: servings,
      personId: _identity(value['personId']),
      personRevision: _positiveRevision(value['expectedPersonRevision']),
      personAclRevision: _positiveRevision(value['expectedPersonAclRevision']),
    );
  }

  final String id, date, recipeId, personId;
  final MealSlot slot;
  final int servings, personRevision, personAclRevision;

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'date': date,
    'slot': slot.name,
    'recipeId': recipeId,
    'servings': servings,
    'personId': personId,
    'expectedPersonRevision': personRevision,
    'expectedPersonAclRevision': personAclRevision,
  };
}

final class WeeklyMealPlan {
  const WeeklyMealPlan({
    required this.revision,
    required this.weekStart,
    required this.recipes,
    required this.entries,
  });

  factory WeeklyMealPlan.fromJson(Object? json) {
    final value = serverObject(json);
    _keys(value, const {
      'schemaVersion',
      'revision',
      'weekStart',
      'recipes',
      'entries',
    });
    if (value['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final start = DateTime.tryParse(
      value['weekStart'] is String ? value['weekStart'] as String : '',
    );
    final recipes = _list(
      value['recipes'],
      32,
    ).map(MealRecipe.fromJson).toList(growable: false);
    final entries = _list(
      value['entries'],
      28,
    ).map(MealPlanEntry.fromJson).toList(growable: false);
    final recipeIds = recipes.map((value) => value.id).toSet();
    final entryIds = entries.map((value) => value.id).toSet();
    final canonicalStart = start == null
        ? null
        : '${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
    if (start == null ||
        canonicalStart != value['weekStart'] ||
        start.weekday != DateTime.monday ||
        recipeIds.length != recipes.length ||
        entryIds.length != entries.length ||
        entries.any((value) {
          final day = DateTime.parse(value.date);
          return !recipeIds.contains(value.recipeId) ||
              day.isBefore(start) ||
              !day.isBefore(start.add(const Duration(days: 7)));
        })) {
      throw const LarenorServerException('invalid_response');
    }
    return WeeklyMealPlan(
      revision: _positiveRevision(value['revision']),
      weekStart: value['weekStart'] as String,
      recipes: List.unmodifiable(recipes),
      entries: List.unmodifiable(entries),
    );
  }

  final int revision;
  final String weekStart;
  final List<MealRecipe> recipes;
  final List<MealPlanEntry> entries;

  MealRecipe recipeFor(MealPlanEntry entry) => recipes.singleWhere(
    (value) => value.id == entry.recipeId,
    orElse: () => throw const LarenorServerException('invalid_response'),
  );

  Map<String, dynamic> toFieldsJson() => {
    'weekStart': weekStart,
    'recipes': recipes.map((value) => value.toJson()).toList(),
    'entries': entries.map((value) => value.toJson()).toList(),
  };
}

final class MealPlanAuthority {
  const MealPlanAuthority({
    required this.context,
    required this.accountId,
    required this.sessionFamilyId,
    required this.accountRevision,
    required this.planRevision,
  });

  factory MealPlanAuthority.fromJson(Object? json, ServerContext expected) {
    final value = serverObject(json);
    _keys(value, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'sessionFamilyId',
      'accountRevision',
      'planRevision',
    });
    final context = ServerContext.fromJson({
      'schemaVersion': value['schemaVersion'],
      'coreId': value['coreId'],
      'homeId': value['homeId'],
    });
    if (context != expected) {
      throw const LarenorServerException('invalid_response');
    }
    return MealPlanAuthority(
      context: context,
      accountId: _identity(value['accountId']),
      sessionFamilyId: _identity(value['sessionFamilyId']),
      accountRevision: _positiveRevision(value['accountRevision']),
      planRevision: _revision(value['planRevision']),
    );
  }

  final ServerContext context;
  final String accountId, sessionFamilyId;
  final int accountRevision, planRevision;
}

final class WeeklyMealPlanSnapshot {
  const WeeklyMealPlanSnapshot({required this.authority, required this.plan});

  factory WeeklyMealPlanSnapshot.fromJson(Object? json, ServerContext context) {
    final value = serverObject(json);
    _keys(value, const {'authority', 'plan'});
    final authority = MealPlanAuthority.fromJson(value['authority'], context);
    final plan = value['plan'] == null
        ? null
        : WeeklyMealPlan.fromJson(value['plan']);
    if (plan != null && plan.revision != authority.planRevision ||
        plan == null && authority.planRevision != 0) {
      throw const LarenorServerException('invalid_response');
    }
    return WeeklyMealPlanSnapshot(authority: authority, plan: plan);
  }

  final MealPlanAuthority authority;
  final WeeklyMealPlan? plan;
}
