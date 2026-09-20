import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

@immutable
final class IngredientDeductionItem {
  const IngredientDeductionItem({
    required this.stockItemId,
    required this.quantityMicros,
  });
  final String stockItemId;
  final int quantityMicros;
}

@immutable
final class IngredientDeductionDraft {
  const IngredientDeductionDraft({
    required this.accountId,
    required this.recipeSessionId,
    required this.recipeRevision,
    required this.completedStep,
    required this.stepRevision,
    required this.expectedPantryRevision,
    required this.items,
  });
  final String accountId;
  final String recipeSessionId;
  final int recipeRevision;
  final int completedStep;
  final int stepRevision;
  final int expectedPantryRevision;
  final List<IngredientDeductionItem> items;
}

@immutable
final class IngredientDeductionPreview {
  IngredientDeductionPreview._({
    required this.idempotencyKey,
    required this.accountId,
    required this.recipeSessionId,
    required this.recipeRevision,
    required this.completedStep,
    required this.stepRevision,
    required this.expectedPantryRevision,
    required List<IngredientDeductionItem> items,
  }) : items = List.unmodifiable(items);

  factory IngredientDeductionPreview.fromDraft(IngredientDeductionDraft draft) {
    bool identity(String value) =>
        RegExp(r'^[A-Za-z0-9_.:-]{1,128}$').hasMatch(value);
    if (!identity(draft.accountId) ||
        !identity(draft.recipeSessionId) ||
        draft.recipeRevision < 1 ||
        draft.completedStep < 0 ||
        draft.stepRevision < 1 ||
        draft.expectedPantryRevision < 1 ||
        draft.items.isEmpty ||
        draft.items.length > 100) {
      throw const FormatException('invalid_ingredient_deduction');
    }
    final sorted = List<IngredientDeductionItem>.of(draft.items)
      ..sort((a, b) => a.stockItemId.compareTo(b.stockItemId));
    final identifiers = <String>{};
    if (sorted.any(
      (item) =>
          !identity(item.stockItemId) ||
          !identifiers.add(item.stockItemId) ||
          item.quantityMicros < 1 ||
          item.quantityMicros > 1000000000000,
    )) {
      throw const FormatException('invalid_ingredient_deduction');
    }
    final canonical = jsonEncode([
      'larenor-ingredient-deduction-v1',
      draft.accountId,
      draft.recipeSessionId,
      draft.recipeRevision,
      draft.completedStep,
      draft.stepRevision,
      draft.expectedPantryRevision,
      for (final item in sorted) [item.stockItemId, item.quantityMicros],
    ]);
    return IngredientDeductionPreview._(
      idempotencyKey: sha256.convert(utf8.encode(canonical)).toString(),
      accountId: draft.accountId,
      recipeSessionId: draft.recipeSessionId,
      recipeRevision: draft.recipeRevision,
      completedStep: draft.completedStep,
      stepRevision: draft.stepRevision,
      expectedPantryRevision: draft.expectedPantryRevision,
      items: sorted,
    );
  }

  final String idempotencyKey;
  final String accountId;
  final String recipeSessionId;
  final int recipeRevision;
  final int completedStep;
  final int stepRevision;
  final int expectedPantryRevision;
  final List<IngredientDeductionItem> items;
}

@immutable
final class IngredientDeductionReceipt {
  IngredientDeductionReceipt({
    required this.idempotencyKey,
    required this.accountId,
    required this.pantryRevision,
    required List<IngredientDeductionItem> applied,
  }) : applied = List.unmodifiable(applied);
  final String idempotencyKey;
  final String accountId;
  final int pantryRevision;
  final List<IngredientDeductionItem> applied;
}
