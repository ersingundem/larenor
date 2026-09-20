import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/cooking_assistant/data/ingredient_deduction_controller.dart';
import 'package:larenor/features/cooking_assistant/domain/ingredient_deduction.dart';

final class _Gateway implements IngredientDeductionGateway {
  int commits = 0;
  bool delay = false;
  bool loseAcknowledgement = false;
  final Completer<IngredientDeductionReceipt> pending = Completer();
  IngredientDeductionReceipt? retained;

  @override
  Future<IngredientDeductionReceipt> commit(
    IngredientDeductionPreview preview,
  ) async {
    commits++;
    if (delay) return pending.future;
    final value = retained ??= IngredientDeductionReceipt(
      idempotencyKey: preview.idempotencyKey,
      accountId: preview.accountId,
      pantryRevision: preview.expectedPantryRevision + 1,
      applied: preview.items,
    );
    if (loseAcknowledgement) throw StateError('lost_ack');
    return value;
  }

  @override
  Future<IngredientDeductionReceipt?> receipt(String idempotencyKey) async =>
      retained;
}

IngredientDeductionDraft draft() => const IngredientDeductionDraft(
  accountId: 'account-a',
  recipeSessionId: 'session-1',
  recipeRevision: 7,
  completedStep: 2,
  stepRevision: 4,
  expectedPantryRevision: 12,
  items: [
    IngredientDeductionItem(stockItemId: 'flour', quantityMicros: 250000),
    IngredientDeductionItem(stockItemId: 'salt', quantityMicros: 5000),
  ],
);

void main() {
  test('preview is deterministic, bounded and exact-revision scoped', () {
    final first = IngredientDeductionPreview.fromDraft(draft());
    final second = IngredientDeductionPreview.fromDraft(draft());
    expect(first.idempotencyKey, second.idempotencyKey);
    expect(first.recipeRevision, 7);
    expect(first.stepRevision, 4);
    expect(first.expectedPantryRevision, 12);
    expect(
      () => IngredientDeductionPreview.fromDraft(
        IngredientDeductionDraft(
          accountId: 'account-a',
          recipeSessionId: 'session-1',
          recipeRevision: 7,
          completedStep: 2,
          stepRevision: 4,
          expectedPantryRevision: 12,
          items: List.generate(
            101,
            (index) => IngredientDeductionItem(
              stockItemId: 'item-$index',
              quantityMicros: 1,
            ),
          ),
        ),
      ),
      throwsFormatException,
    );
  });

  test('explicit commit accepts only exact idempotent receipt', () async {
    final gateway = _Gateway();
    final controller = IngredientDeductionController(
      gateway: gateway,
      preview: IngredientDeductionPreview.fromDraft(draft()),
      isCurrent: () => true,
    );
    expect(await controller.confirm(), isTrue);
    expect(await controller.confirm(), isTrue);
    expect(gateway.commits, 1);
    expect(controller.receipt?.pantryRevision, 13);
  });

  test(
    'stale late receipt is discarded and never replayed automatically',
    () async {
      var current = true;
      final gateway = _Gateway()..delay = true;
      final controller = IngredientDeductionController(
        gateway: gateway,
        preview: IngredientDeductionPreview.fromDraft(draft()),
        isCurrent: () => current,
      );
      final operation = controller.confirm();
      current = false;
      gateway.pending.complete(
        IngredientDeductionReceipt(
          idempotencyKey: controller.preview.idempotencyKey,
          accountId: 'account-a',
          pantryRevision: 13,
          applied: controller.preview.items,
        ),
      );
      expect(await operation, isFalse);
      expect(controller.receipt, isNull);
      expect(gateway.commits, 1);
      expect(await controller.confirm(), isFalse);
      expect(gateway.commits, 1);
    },
  );

  test('lost acknowledgement reconciles without command replay', () async {
    final gateway = _Gateway()..loseAcknowledgement = true;
    final controller = IngredientDeductionController(
      gateway: gateway,
      preview: IngredientDeductionPreview.fromDraft(draft()),
      isCurrent: () => true,
    );
    expect(await controller.confirm(), isFalse);
    expect(controller.failure, IngredientDeductionFailure.uncertain);
    expect(await controller.confirm(), isFalse);
    expect(gateway.commits, 1);
    expect(await controller.reconcile(), isTrue);
    expect(gateway.commits, 1);
    expect(controller.receipt?.pantryRevision, 13);
  });
}
