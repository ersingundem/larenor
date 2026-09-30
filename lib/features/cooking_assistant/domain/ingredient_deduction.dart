import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

enum IngredientDeductionUnit {
  gram('g'),
  milliliter('ml'),
  piece('piece');

  const IngredientDeductionUnit(this.wire);
  final String wire;
}

@immutable
final class IngredientDeductionItem {
  const IngredientDeductionItem({
    required this.stockItemId,
    required this.quantityMicros,
    this.unit = IngredientDeductionUnit.gram,
  });
  final String stockItemId;
  final int quantityMicros;
  final IngredientDeductionUnit unit;

  Map<String, Object> toJson() => {
    'stockItemId': stockItemId,
    'quantityMicros': quantityMicros,
    'unit': unit.wire,
  };
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
          item.quantityMicros > 10000000,
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
      [
        for (final item in sorted)
          [item.stockItemId, item.quantityMicros, item.unit.wire],
      ],
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

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'idempotencyKey': idempotencyKey,
    'recipeRevision': recipeRevision,
    'completedStep': completedStep,
    'stepRevision': stepRevision,
    'expectedPantryRevision': expectedPantryRevision,
    'items': items.map((item) => item.toJson()).toList(growable: false),
  };
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

  factory IngredientDeductionReceipt.fromResponse(
    Object? raw, {
    required IngredientDeductionPreview expected,
  }) {
    if (raw is! Map<String, dynamic> ||
        raw.length != 2 ||
        raw['schemaVersion'] != 1 ||
        raw['receipt'] is! Map<String, dynamic>) {
      throw const FormatException('invalid_ingredient_deduction_receipt');
    }
    final value = raw['receipt'] as Map<String, dynamic>;
    const keys = {
      'schemaVersion',
      'idempotencyKey',
      'accountId',
      'pantryRevision',
      'applied',
    };
    if (value.length != keys.length ||
        !keys.every(value.containsKey) ||
        value['schemaVersion'] != 1 ||
        value['idempotencyKey'] != expected.idempotencyKey ||
        value['accountId'] != expected.accountId ||
        value['pantryRevision'] !=
            expected.expectedPantryRevision + expected.items.length ||
        value['applied'] is! List) {
      throw const FormatException('invalid_ingredient_deduction_receipt');
    }
    final rows = value['applied'] as List<dynamic>;
    if (rows.length != expected.items.length) {
      throw const FormatException('invalid_ingredient_deduction_receipt');
    }
    final applied = <IngredientDeductionItem>[];
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final expectedItem = expected.items[index];
      if (row is! Map<String, dynamic> ||
          row.length != 3 ||
          row['stockItemId'] != expectedItem.stockItemId ||
          row['quantityMicros'] != expectedItem.quantityMicros ||
          row['unit'] != expectedItem.unit.wire) {
        throw const FormatException('invalid_ingredient_deduction_receipt');
      }
      applied.add(expectedItem);
    }
    return IngredientDeductionReceipt(
      idempotencyKey: expected.idempotencyKey,
      accountId: expected.accountId,
      pantryRevision: value['pantryRevision'] as int,
      applied: applied,
    );
  }
}
