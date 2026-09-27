import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';

import '../data/pantry_stock_controller.dart';
import '../domain/pantry_stock_models.dart';

final class PantryStockStrings {
  const PantryStockStrings({
    required this.title,
    required this.addStock,
    required this.consumeStock,
    required this.ingredient,
    required this.quantity,
    required this.unit,
    required this.expiry,
    required this.barcode,
    required this.add,
    required this.consume,
    required this.undo,
    required this.currentStock,
    required this.empty,
    required this.loading,
    required this.invalidForm,
    required this.error,
    required this.noExpiry,
  });

  static const tr = PantryStockStrings(
    title: 'Dolap stoğu',
    addStock: 'Stok ekle',
    consumeStock: 'Stoktan kullan',
    ingredient: 'Ürün anahtarı',
    quantity: 'Miktar',
    unit: 'Birim',
    expiry: 'Son kullanma (YYYY-AA-GG)',
    barcode: 'Barkod / lot kodu (isteğe bağlı)',
    add: 'Stoğa ekle',
    consume: 'Kullan',
    undo: 'Son tüketimi geri al',
    currentStock: 'Mevcut lotlar',
    empty: 'Dolapta kayıtlı stok yok',
    loading: 'Güncel stok doğrulanıyor',
    invalidForm: 'Ürün, miktar ve tarih alanlarını denetleyin',
    error: 'Güncel stok işlemi tamamlanamadı',
    noExpiry: 'Son kullanma tarihi yok',
  );

  static const en = PantryStockStrings(
    title: 'Pantry stock',
    addStock: 'Add stock',
    consumeStock: 'Consume stock',
    ingredient: 'Ingredient key',
    quantity: 'Quantity',
    unit: 'Unit',
    expiry: 'Expiry (YYYY-MM-DD)',
    barcode: 'Barcode / lot code (optional)',
    add: 'Add to pantry',
    consume: 'Consume',
    undo: 'Undo last consumption',
    currentStock: 'Current lots',
    empty: 'No pantry stock recorded',
    loading: 'Verifying current stock',
    invalidForm: 'Check the ingredient, quantity and expiry fields',
    error: 'The current stock operation could not be completed',
    noExpiry: 'No expiry date',
  );

  factory PantryStockStrings.of(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'tr' ? tr : en;

  final String title;
  final String addStock;
  final String consumeStock;
  final String ingredient;
  final String quantity;
  final String unit;
  final String expiry;
  final String barcode;
  final String add;
  final String consume;
  final String undo;
  final String currentStock;
  final String empty;
  final String loading;
  final String invalidForm;
  final String error;
  final String noExpiry;
}

final class PantryStockScreen extends StatefulWidget {
  const PantryStockScreen({
    super.key,
    required this.controller,
    required this.idFactory,
  });

  final PantryStockController controller;
  final String Function() idFactory;

  @override
  State<PantryStockScreen> createState() => _PantryStockScreenState();
}

final class _PantryStockScreenState extends State<PantryStockScreen> {
  final _addIngredient = TextEditingController();
  final _addQuantity = TextEditingController();
  final _expiry = TextEditingController();
  final _barcode = TextEditingController();
  final _consumeIngredient = TextEditingController();
  final _consumeQuantity = TextEditingController();
  PantryUnit _addUnit = PantryUnit.piece;
  PantryUnit _consumeUnit = PantryUnit.piece;
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.controller.load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant PantryStockScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      widget.controller.load();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    for (final controller in [
      _addIngredient,
      _addQuantity,
      _expiry,
      _barcode,
      _consumeIngredient,
      _consumeQuantity,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String _ingredient(TextEditingController controller) =>
      controller.text.trim().toLowerCase();

  String? _expiryValue() {
    final raw = _expiry.text.trim();
    if (raw.isEmpty) return null;
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) return '';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null || parsed.toIso8601String().substring(0, 10) != raw) {
      return '';
    }
    return raw;
  }

  Future<void> _receive() async {
    final ingredient = _ingredient(_addIngredient);
    final amount = PantryAmount.tryParse(_addQuantity.text, _addUnit);
    final expiry = _expiryValue();
    if (ingredient.isEmpty ||
        ingredient.length > 80 ||
        amount == null ||
        expiry == '') {
      setState(() => _invalid = true);
      return;
    }
    final barcode = _barcode.text.trim();
    final lotId = barcode.isEmpty
        ? widget.idFactory()
        : sha256
              .convert(utf8.encode('larenor-f32-lot-v1\u0000$barcode'))
              .toString()
              .substring(0, 32);
    final accepted = await widget.controller.receive(
      PantryLotDraft(
        id: lotId,
        ingredientKey: ingredient,
        amount: amount,
        expiresOn: expiry,
      ),
    );
    if (!mounted) return;
    if (accepted) {
      _addIngredient.clear();
      _addQuantity.clear();
      _expiry.clear();
      _barcode.clear();
    }
    setState(() => _invalid = false);
  }

  Future<void> _consume() async {
    final ingredient = _ingredient(_consumeIngredient);
    final amount = PantryAmount.tryParse(_consumeQuantity.text, _consumeUnit);
    if (ingredient.isEmpty || ingredient.length > 80 || amount == null) {
      setState(() => _invalid = true);
      return;
    }
    final accepted = await widget.controller.consume(ingredient, amount);
    if (!mounted) return;
    if (accepted) _consumeQuantity.clear();
    setState(() => _invalid = false);
  }

  @override
  Widget build(BuildContext context) {
    final strings = PantryStockStrings.of(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(strings.title)),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final width = wide
                  ? (constraints.maxWidth - 16) / 2
                  : constraints.maxWidth;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.controller.busy)
                    Semantics(
                      liveRegion: true,
                      label: strings.loading,
                      child: const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: CupertinoActivityIndicator(),
                      ),
                    ),
                  if (_invalid || widget.controller.failure != null)
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          _invalid ? strings.invalidForm : strings.error,
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      SizedBox(width: width, child: _receivePanel(strings)),
                      SizedBox(width: width, child: _consumePanel(strings)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _stockPanel(strings),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _receivePanel(PantryStockStrings strings) => _Panel(
    title: strings.addStock,
    children: [
      _field(_addIngredient, strings.ingredient, 'pantry-add-ingredient'),
      _field(
        _addQuantity,
        strings.quantity,
        'pantry-add-quantity',
        keyboard: const TextInputType.numberWithOptions(decimal: true),
      ),
      _unitPicker(
        strings,
        _addUnit,
        (value) => setState(() => _addUnit = value),
      ),
      _field(_expiry, strings.expiry, 'pantry-expiry'),
      _field(_barcode, strings.barcode, 'pantry-barcode'),
      CupertinoButton.filled(
        key: const ValueKey('pantry-receive'),
        onPressed: widget.controller.busy ? null : _receive,
        child: Text(strings.add),
      ),
    ],
  );

  Widget _consumePanel(PantryStockStrings strings) => _Panel(
    title: strings.consumeStock,
    children: [
      _field(
        _consumeIngredient,
        strings.ingredient,
        'pantry-consume-ingredient',
      ),
      _field(
        _consumeQuantity,
        strings.quantity,
        'pantry-consume-quantity',
        keyboard: const TextInputType.numberWithOptions(decimal: true),
      ),
      _unitPicker(
        strings,
        _consumeUnit,
        (value) => setState(() => _consumeUnit = value),
      ),
      CupertinoButton.filled(
        key: const ValueKey('pantry-consume'),
        onPressed: widget.controller.busy ? null : _consume,
        child: Text(strings.consume),
      ),
      if (widget.controller.undoMovementId != null)
        CupertinoButton(
          key: const ValueKey('pantry-undo'),
          onPressed: widget.controller.busy ? null : widget.controller.undo,
          child: Text(strings.undo),
        ),
    ],
  );

  Widget _stockPanel(PantryStockStrings strings) {
    final lots = [...?widget.controller.snapshot?.lots]
      ..sort((left, right) {
        final leftDate = left.expiresOn ?? '9999-12-31';
        final rightDate = right.expiresOn ?? '9999-12-31';
        final date = leftDate.compareTo(rightDate);
        return date != 0
            ? date
            : left.ingredientKey.compareTo(right.ingredientKey);
      });
    return _Panel(
      title: strings.currentStock,
      children: lots.isEmpty
          ? [Text(strings.empty)]
          : [
              for (final lot in lots)
                Container(
                  key: ValueKey('pantry-lot-${lot.lotId}'),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: CupertinoColors.separator),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              lot.ingredientKey,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(lot.expiresOn ?? strings.noExpiry),
                          ],
                        ),
                      ),
                      Text(lot.quantityLabel()),
                    ],
                  ),
                ),
            ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String placeholder,
    String key, {
    TextInputType? keyboard,
  }) => CupertinoTextField(
    key: ValueKey(key),
    controller: controller,
    placeholder: placeholder,
    keyboardType: keyboard,
    autocorrect: false,
    padding: const EdgeInsets.all(14),
  );

  Widget _unitPicker(
    PantryStockStrings strings,
    PantryUnit value,
    ValueChanged<PantryUnit> changed,
  ) => Row(
    children: [
      Expanded(child: Text(strings.unit)),
      CupertinoButton(
        onPressed: widget.controller.busy
            ? null
            : () => showCupertinoModalPopup<void>(
                context: context,
                builder: (context) => CupertinoActionSheet(
                  title: Text(strings.unit),
                  actions: [
                    for (final unit in PantryUnit.values)
                      CupertinoActionSheetAction(
                        onPressed: () {
                          Navigator.pop(context);
                          changed(unit);
                        },
                        child: Text(unit.wire),
                      ),
                  ],
                  cancelButton: CupertinoActionSheetAction(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
        child: Text(value.wire),
      ),
    ],
  );
}

final class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: CupertinoDynamicColor.resolve(
        CupertinoColors.systemBackground,
        context,
      ),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: CupertinoDynamicColor.resolve(
          CupertinoColors.separator,
          context,
        ),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 14),
        for (var index = 0; index < children.length; index++) ...[
          children[index],
          if (index != children.length - 1) const SizedBox(height: 10),
        ],
      ],
    ),
  );
}
