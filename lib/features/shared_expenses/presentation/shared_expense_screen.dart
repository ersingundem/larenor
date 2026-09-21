import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/shared_expense_controller.dart';
import '../domain/shared_expense_models.dart';

class SharedExpenseStrings {
  const SharedExpenseStrings({
    required this.title,
    required this.newExpense,
    required this.expenseTitle,
    required this.amount,
    required this.participants,
    required this.payer,
    required this.splitPreview,
    required this.create,
    required this.history,
    required this.export,
    required this.exportReady,
    required this.loading,
    required this.empty,
    required this.offline,
    required this.error,
    required this.uncertain,
    required this.reconcile,
    required this.decimalSeparator,
  });

  static const en = SharedExpenseStrings(
    title: 'Shared expenses',
    newExpense: 'New expense',
    expenseTitle: 'Expense title',
    amount: 'Amount',
    participants: 'Participants',
    payer: 'Paid by',
    splitPreview: 'Split preview',
    create: 'Save expense',
    history: 'Expense history',
    export: 'Read my expense export',
    exportReady: 'Filtered export is ready',
    loading: 'Loading current ledger',
    empty: 'No recorded expenses',
    offline: 'Core is not reachable',
    error: 'Current expense state could not be verified',
    uncertain:
        'The save result is uncertain. Read its receipt before retrying.',
    reconcile: 'Check save result',
    decimalSeparator: '.',
  );

  static const tr = SharedExpenseStrings(
    title: 'Ortak giderler',
    newExpense: 'Yeni gider',
    expenseTitle: 'Gider başlığı',
    amount: 'Tutar',
    participants: 'Katılımcılar',
    payer: 'Ödeyen',
    splitPreview: 'Paylaşım önizlemesi',
    create: 'Gideri kaydet',
    history: 'Gider geçmişi',
    export: 'Bana ait gider dışa aktarımını oku',
    exportReady: 'Filtrelenmiş dışa aktarım hazır',
    loading: 'Güncel gider defteri yükleniyor',
    empty: 'Kayıtlı gider yok',
    offline: 'Core erişilebilir değil',
    error: 'Güncel gider durumu doğrulanamadı',
    uncertain: 'Kayıt sonucu belirsiz. Yeniden denemeden önce makbuzu okuyun.',
    reconcile: 'Kayıt sonucunu denetle',
    decimalSeparator: ',',
  );

  factory SharedExpenseStrings.fromLocalizations(AppLocalizations l10n) =>
      SharedExpenseStrings(
        title: l10n.sharedExpensesTitle,
        newExpense: l10n.sharedExpensesNew,
        expenseTitle: l10n.sharedExpensesExpenseTitle,
        amount: l10n.sharedExpensesAmount,
        participants: l10n.sharedExpensesParticipants,
        payer: l10n.sharedExpensesPayer,
        splitPreview: l10n.sharedExpensesSplitPreview,
        create: l10n.sharedExpensesCreate,
        history: l10n.sharedExpensesHistory,
        export: l10n.sharedExpensesExport,
        exportReady: l10n.sharedExpensesExportReady,
        loading: l10n.sharedExpensesLoading,
        empty: l10n.sharedExpensesEmpty,
        offline: l10n.sharedExpensesOffline,
        error: l10n.sharedExpensesError,
        uncertain: l10n.sharedExpensesUncertain,
        reconcile: l10n.sharedExpensesReconcile,
        decimalSeparator: l10n.sharedExpensesDecimalSeparator,
      );

  final String title;
  final String newExpense;
  final String expenseTitle;
  final String amount;
  final String participants;
  final String payer;
  final String splitPreview;
  final String create;
  final String history;
  final String export;
  final String exportReady;
  final String loading;
  final String empty;
  final String offline;
  final String error;
  final String uncertain;
  final String reconcile;
  final String decimalSeparator;
}

class SharedExpenseScreen extends StatefulWidget {
  const SharedExpenseScreen({
    super.key,
    required this.controller,
    required this.authority,
    required this.strings,
  });

  final SharedExpenseController controller;
  final SharedExpenseAuthority authority;
  final SharedExpenseStrings strings;

  @override
  State<SharedExpenseScreen> createState() => _SharedExpenseScreenState();
}

class _SharedExpenseScreenState extends State<SharedExpenseScreen> {
  final _title = TextEditingController();
  final _amount = TextEditingController();
  final _selected = <String>{};
  late SharedExpenseLease _lease;
  String _currency = 'TRY';

  @override
  void initState() {
    super.initState();
    _title.addListener(_changed);
    _amount.addListener(_changed);
    _attach();
  }

  void _attach() {
    _selected.clear();
    _lease = widget.controller.bind(widget.authority);
    widget.controller.addListener(_controllerChanged);
    widget.controller.load(_lease);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _controllerChanged() {
    if (!mounted) return;
    if (_selected.isEmpty && widget.controller.participants.isNotEmpty) {
      _selected.addAll(
        widget.controller.participants.map((person) => person.id),
      );
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant SharedExpenseScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.authority != widget.authority) {
      oldWidget.controller.removeListener(_controllerChanged);
      oldWidget.controller.detach(_lease);
      _title.clear();
      _amount.clear();
      _currency = 'TRY';
      _attach();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    widget.controller.detach(_lease);
    _title.removeListener(_changed);
    _amount.removeListener(_changed);
    _title.dispose();
    _amount.dispose();
    super.dispose();
  }

  ExpenseDraft? get _draft => ExpenseDraft.tryParse(
    title: _title.text,
    currency: _currency,
    amount: _amount.text,
    payerId: widget.authority.accountId,
    participantIds: _selected,
  );

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(middle: Text(widget.strings.title)),
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final width = wide
              ? (constraints.maxWidth - 80) / 2
              : constraints.maxWidth - 32;
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: wide ? 32 : 16,
              vertical: 24,
            ),
            child: Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                SizedBox(width: width, child: _editor()),
                SizedBox(width: width, child: _history()),
              ],
            ),
          );
        },
      ),
    ),
  );

  Widget _editor() {
    final strings = widget.strings;
    final draft = _draft;
    final canCreate =
        widget.controller.state == SharedExpenseViewState.ready ||
        widget.controller.state == SharedExpenseViewState.empty;
    return _Panel(
      title: strings.newExpense,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CupertinoTextField(
            key: const ValueKey('expense-title'),
            controller: _title,
            minLines: 1,
            maxLength: 200,
            padding: const EdgeInsets.all(14),
            placeholder: strings.expenseTitle,
          ),
          const SizedBox(height: 12),
          CupertinoTextField(
            key: const ValueKey('expense-amount'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            padding: const EdgeInsets.all(14),
            placeholder: strings.amount,
          ),
          const SizedBox(height: 12),
          CupertinoSlidingSegmentedControl<String>(
            groupValue: _currency,
            children: const {
              'TRY': Text('TRY'),
              'EUR': Text('EUR'),
              'JPY': Text('JPY'),
            },
            onValueChanged: (value) =>
                setState(() => _currency = value ?? _currency),
          ),
          const SizedBox(height: 16),
          Text(
            strings.participants,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final person in widget.controller.participants)
                SizedBox(
                  height: 48,
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    color: _selected.contains(person.id)
                        ? CupertinoColors.activeBlue
                        : CupertinoColors.systemGrey5,
                    onPressed: () => setState(() {
                      if (!_selected.remove(person.id)) {
                        _selected.add(person.id);
                      }
                    }),
                    child: Text(person.label),
                  ),
                ),
            ],
          ),
          if (draft != null) ...[
            const SizedBox(height: 16),
            Text(
              strings.splitPreview,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            for (final share in draft.shares)
              Text(
                '${_label(share.accountId)} · '
                '${formatExpenseMinor(share.amountMinor, draft.currencyScale, separator: strings.decimalSeparator)} ${draft.currency}',
              ),
          ],
          const SizedBox(height: 16),
          _ActionButton(
            key: const ValueKey('expense-create'),
            label: strings.create,
            onPressed: draft == null || !canCreate
                ? null
                : () => widget.controller.create(_lease, draft),
          ),
        ],
      ),
    );
  }

  String _label(String id) =>
      widget.controller.participants
          .where((person) => person.id == id)
          .map((person) => person.label)
          .firstOrNull ??
      id;

  Widget _history() {
    final strings = widget.strings;
    final state = widget.controller.state;
    final status = switch (state) {
      SharedExpenseViewState.detached ||
      SharedExpenseViewState.idle ||
      SharedExpenseViewState.loading => strings.loading,
      SharedExpenseViewState.empty => strings.empty,
      SharedExpenseViewState.offline => strings.offline,
      SharedExpenseViewState.error => strings.error,
      SharedExpenseViewState.uncertain => strings.uncertain,
      _ => null,
    };
    return _Panel(
      title: strings.history,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (status != null) Semantics(liveRegion: true, child: Text(status)),
          for (final record in widget.controller.records) ...[
            Text(
              record.title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              '${formatExpenseMinor(record.totalMinor, record.currencyScale, separator: strings.decimalSeparator)} ${record.currency}',
            ),
            const SizedBox(height: 12),
          ],
          if (state == SharedExpenseViewState.uncertain)
            _ActionButton(
              label: strings.reconcile,
              onPressed: () => widget.controller.reconcile(_lease),
            ),
          _ActionButton(
            key: const ValueKey('expense-export'),
            label: strings.export,
            onPressed:
                state == SharedExpenseViewState.ready ||
                    state == SharedExpenseViewState.empty
                ? () => widget.controller.readExport(_lease)
                : null,
          ),
          if (widget.controller.exportedRecords.isNotEmpty)
            Semantics(
              key: const ValueKey('expense-export-result'),
              liveRegion: true,
              label: strings.exportReady,
              child: Text(strings.exportReady),
            ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: label,
    onTap: onPressed,
    excludeSemantics: true,
    child: SizedBox(
      height: 48,
      child: CupertinoButton.filled(onPressed: onPressed, child: Text(label)),
    ),
  );
}
