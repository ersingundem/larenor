import 'package:flutter/material.dart';

import '../data/ingredient_deduction_controller.dart';
import '../domain/ingredient_deduction.dart';

@immutable
final class IngredientDeductionStrings {
  const IngredientDeductionStrings({
    required this.title,
    required this.explanation,
    required this.confirm,
    required this.reconcile,
    required this.applied,
    required this.uncertain,
    required this.unavailable,
    required this.stale,
    required this.invalid,
  });

  static const en = IngredientDeductionStrings(
    title: 'Deduct used ingredients',
    explanation: 'Review the amounts before updating pantry stock. Nothing is deducted automatically.',
    confirm: 'Confirm deduction',
    reconcile: 'Check previous result',
    applied: 'Pantry stock was updated.',
    uncertain: 'The result is uncertain. Check the previous result without repeating the deduction.',
    unavailable: 'Pantry stock is unavailable. Try again.',
    stale: 'Account or cooking session changed. Reopen this session.',
    invalid: 'The pantry receipt was rejected.',
  );

  static const tr = IngredientDeductionStrings(
    title: 'Kullanılan malzemeleri stoktan düş',
    explanation: 'Kiler stoğunu güncellemeden önce miktarları inceleyin. Hiçbir malzeme otomatik düşülmez.',
    confirm: 'Düşümü onayla',
    reconcile: 'Önceki sonucu kontrol et',
    applied: 'Kiler stoğu güncellendi.',
    uncertain:
        'Sonuç belirsiz. Düşümü tekrarlamadan önceki sonucu kontrol edin.',
    unavailable: 'Kiler stoğuna ulaşılamıyor. Yeniden deneyin.',
    stale: 'Hesap veya pişirme oturumu değişti. Oturumu yeniden açın.',
    invalid: 'Kiler makbuzu reddedildi.',
  );

  final String title;
  final String explanation;
  final String confirm;
  final String reconcile;
  final String applied;
  final String uncertain;
  final String unavailable;
  final String stale;
  final String invalid;
}

class IngredientDeductionCard extends StatefulWidget {
  const IngredientDeductionCard({
    super.key,
    required this.controller,
    required this.strings,
  });

  final IngredientDeductionController controller;
  final IngredientDeductionStrings strings;

  @override
  State<IngredientDeductionCard> createState() =>
      _IngredientDeductionCardState();
}

class _IngredientDeductionCardState extends State<IngredientDeductionCard> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant IngredientDeductionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final strings = widget.strings;
    final failure = controller.failure;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(strings.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(strings.explanation),
            const SizedBox(height: 12),
            for (final item in controller.preview.items)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(item.stockItemId),
                trailing: Text(_quantity(item)),
              ),
            if (controller.receipt != null)
              Text(
                strings.applied,
                key: const Key('ingredient-deduction-applied'),
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              )
            else if (failure != null)
              Text(
                switch (failure) {
                  IngredientDeductionFailure.uncertain => strings.uncertain,
                  IngredientDeductionFailure.unavailable => strings.unavailable,
                  IngredientDeductionFailure.staleAuthority => strings.stale,
                  IngredientDeductionFailure.invalidReceipt => strings.invalid,
                },
                key: const Key('ingredient-deduction-failure'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('ingredient-deduction-confirm'),
                  onPressed:
                      controller.busy ||
                          controller.receipt != null ||
                          failure == IngredientDeductionFailure.uncertain
                      ? null
                      : controller.confirm,
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: Text(strings.confirm),
                ),
                if (failure == IngredientDeductionFailure.uncertain)
                  OutlinedButton.icon(
                    key: const Key('ingredient-deduction-reconcile'),
                    onPressed: controller.busy ? null : controller.reconcile,
                    icon: const Icon(Icons.sync),
                    label: Text(strings.reconcile),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _quantity(IngredientDeductionItem item) {
    final micros = item.quantityMicros;
    final whole = micros ~/ 1000000;
    final remainder = micros.remainder(1000000).toString().padLeft(6, '0');
    final amount = '$whole.${remainder.substring(0, 3)}';
    return '$amount ${switch (item.unit) {
      IngredientDeductionUnit.gram => 'g',
      IngredientDeductionUnit.milliliter => 'ml',
      IngredientDeductionUnit.piece => 'piece',
    }}';
  }
}
