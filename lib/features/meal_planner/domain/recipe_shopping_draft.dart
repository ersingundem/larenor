final class RecipeShoppingException implements Exception {
  const RecipeShoppingException(this.code, {this.completedCount = 0});

  final String code;
  final int completedCount;

  @override
  String toString() => 'RecipeShoppingException($code)';
}

enum RecipeIngredientUnit { gram, kilogram, milliliter, liter, piece }

final class RecipeIngredient {
  const RecipeIngredient._({
    required this.quantityMillis,
    required this.unit,
    required this.name,
  });

  final int quantityMillis;
  final RecipeIngredientUnit unit;
  final String name;

  static RecipeIngredient parse(String source) {
    if (source.length > 160 || source.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const RecipeShoppingException('invalid_ingredient');
    }
    final match = RegExp(
      r'^\s*([0-9]+(?:[.,][0-9]{1,3})?)\s+([^\s]+)\s+(.+?)\s*$',
    ).firstMatch(source);
    if (match == null) {
      throw const RecipeShoppingException('invalid_ingredient');
    }
    final quantity = _parseMillis(match.group(1)!);
    final unit = _parseUnit(match.group(2)!);
    final name = match.group(3)!.trim();
    if (name.isEmpty || name.length > 120) {
      throw const RecipeShoppingException('invalid_ingredient');
    }
    return RecipeIngredient._(quantityMillis: quantity, unit: unit, name: name);
  }

  static int _parseMillis(String value) {
    final parts = value.replaceAll(',', '.').split('.');
    final whole = int.tryParse(parts.first);
    final fraction = parts.length == 1
        ? 0
        : int.tryParse(parts[1].padRight(3, '0'));
    if (whole == null || fraction == null) {
      throw const RecipeShoppingException('invalid_quantity');
    }
    final result = whole * 1000 + fraction;
    if (result <= 0 || result > 10000000) {
      throw const RecipeShoppingException('invalid_quantity');
    }
    return result;
  }

  static RecipeIngredientUnit _parseUnit(String value) {
    return switch (value.toLowerCase()) {
      'g' || 'gr' || 'gram' => RecipeIngredientUnit.gram,
      'kg' || 'kilogram' => RecipeIngredientUnit.kilogram,
      'ml' || 'milliliter' || 'mililitre' => RecipeIngredientUnit.milliliter,
      'l' || 'lt' || 'liter' || 'litre' => RecipeIngredientUnit.liter,
      'piece' ||
      'pieces' ||
      'pcs' ||
      'adet' ||
      'tane' => RecipeIngredientUnit.piece,
      _ => throw const RecipeShoppingException('unsupported_unit'),
    };
  }

  String scaledSummary(int baseServings, int targetServings, String locale) {
    final scaled =
        (quantityMillis * targetServings + baseServings ~/ 2) ~/ baseServings;
    if (scaled <= 0 || scaled > 10000000) {
      throw const RecipeShoppingException('invalid_quantity');
    }
    final language = locale.toLowerCase().split(RegExp('[-_]')).first;
    final decimal = language == 'tr' ? ',' : '.';
    final whole = scaled ~/ 1000;
    final remainder = scaled % 1000;
    final quantity = remainder == 0
        ? '$whole'
        : '$whole$decimal${remainder.toString().padLeft(3, '0').replaceFirst(RegExp(r'0+$'), '')}';
    final unitLabel = switch (unit) {
      RecipeIngredientUnit.gram => 'g',
      RecipeIngredientUnit.kilogram => 'kg',
      RecipeIngredientUnit.milliliter => 'ml',
      RecipeIngredientUnit.liter => 'l',
      RecipeIngredientUnit.piece => language == 'tr' ? 'adet' : 'pcs',
    };
    return '$quantity $unitLabel $name';
  }
}

final class RecipeShoppingDraft {
  const RecipeShoppingDraft._({
    required this.title,
    required this.baseServings,
    required this.targetServings,
    required this.ingredients,
  });

  final String title;
  final int baseServings;
  final int targetServings;
  final List<RecipeIngredient> ingredients;

  factory RecipeShoppingDraft.parse({
    required String title,
    required String baseServingsText,
    required String targetServingsText,
    required String ingredientLines,
  }) {
    final safeTitle = title.trim();
    if (safeTitle.isEmpty ||
        safeTitle.length > 100 ||
        safeTitle.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const RecipeShoppingException('invalid_title');
    }
    final base = int.tryParse(baseServingsText.trim());
    final target = int.tryParse(targetServingsText.trim());
    if (base == null ||
        target == null ||
        base < 1 ||
        target < 1 ||
        base > 24 ||
        target > 24) {
      throw const RecipeShoppingException('invalid_servings');
    }
    if (ingredientLines.length > 5200) {
      throw const RecipeShoppingException('too_many_ingredients');
    }
    final lines = ingredientLines
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty || lines.length > 32) {
      throw const RecipeShoppingException('too_many_ingredients');
    }
    return RecipeShoppingDraft._(
      title: safeTitle,
      baseServings: base,
      targetServings: target,
      ingredients: List.unmodifiable(lines.map(RecipeIngredient.parse)),
    );
  }

  List<String> shoppingSummaries(String locale) => List.unmodifiable(
    ingredients.map(
      (ingredient) =>
          ingredient.scaledSummary(baseServings, targetServings, locale),
    ),
  );

  @override
  String toString() =>
      'RecipeShoppingDraft(servings: $baseServings->$targetServings, items: ${ingredients.length})';
}
