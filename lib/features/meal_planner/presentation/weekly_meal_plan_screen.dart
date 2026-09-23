import 'dart:async';
import 'dart:math';

import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/weekly_meal_plan_api.dart';
import '../domain/weekly_meal_plan.dart';

class WeeklyMealPlanScreen extends StatefulWidget {
  const WeeklyMealPlanScreen({
    super.key,
    required this.gateway,
    required this.isCurrent,
    this.onRetire,
  });

  final WeeklyMealPlanGateway gateway;
  final bool Function() isCurrent;
  final VoidCallback? onRetire;

  @override
  State<WeeklyMealPlanScreen> createState() => _WeeklyMealPlanScreenState();
}

class _WeeklyMealPlanScreenState extends State<WeeklyMealPlanScreen>
    with WidgetsBindingObserver {
  WeeklyMealPlanSnapshot? _snapshot;
  bool _loading = false;
  bool _saving = false;
  bool _failed = false;
  bool _saveFailed = false;
  bool _foreground = true;
  int _operation = 0;

  bool get _authorityCurrent {
    if (!mounted || !_foreground) return false;
    try {
      return widget.isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool get _current {
    if (!_authorityCurrent) return false;
    try {
      return TickerMode.valuesOf(context).enabled &&
          (ModalRoute.of(context)?.isCurrent ?? true);
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _retire();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_current) {
      _clear();
    } else if (_snapshot == null && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void didUpdateWidget(covariant WeeklyMealPlanScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.gateway, widget.gateway) || !_current) {
      _clear();
      if (_current) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      }
    }
  }

  void _clear() {
    _operation++;
    _snapshot = null;
    _loading = false;
    _saving = false;
    _failed = false;
    _saveFailed = false;
    try {
      widget.onRetire?.call();
    } catch (_) {
      // Authority retirement callbacks cannot keep old plan state visible.
    }
  }

  void _retire() {
    _clear();
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (_loading || _saving || !_current) return;
    final operation = ++_operation;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final snapshot = await widget.gateway.read();
      if (operation != _operation || !_current) return;
      setState(() => _snapshot = snapshot);
    } catch (_) {
      if (operation == _operation && _current) {
        setState(() {
          _snapshot = null;
          _failed = true;
        });
      }
    } finally {
      if (operation == _operation && mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _editServings(MealPlanEntry entry) async {
    if (_saving || !_current) return;
    final base = _snapshot;
    if (base?.plan == null ||
        !base!.plan!.entries.any((value) => value.id == entry.id)) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: '${entry.servings}');
    var valid = true;
    final value = await showCupertinoDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => CupertinoAlertDialog(
          title: Text(l10n.weeklyMealPlanEditServingsTitle),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              textField: true,
              label: l10n.weeklyMealPlanServingsLabel,
              child: CupertinoTextField(
                key: const ValueKey('meal-edit-servings'),
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                onChanged: (text) {
                  final servings = int.tryParse(text);
                  update(
                    () => valid =
                        servings != null && servings <= 24 && servings > 0,
                  );
                },
              ),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.weeklyMealPlanCancel),
            ),
            CupertinoDialogAction(
              key: const ValueKey('meal-edit-save'),
              onPressed: valid
                  ? () =>
                        Navigator.of(dialogContext)
                            .pop<int>(int.parse(controller.text))
                  : null,
              child: Text(l10n.weeklyMealPlanSave),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (value != null) await _saveServings(base, entry.id, value);
  }

  Future<void> _saveServings(
    WeeklyMealPlanSnapshot base,
    String entryId,
    int servings,
  ) async {
    final plan = base.plan;
    if (_saving || !_authorityCurrent || plan == null) return;
    final entries = plan.entries
        .map(
          (entry) => entry.id == entryId
              ? MealPlanEntry(
                  id: entry.id,
                  date: entry.date,
                  slot: entry.slot,
                  recipeId: entry.recipeId,
                  servings: servings,
                  personId: entry.personId,
                  personRevision: entry.personRevision,
                  personAclRevision: entry.personAclRevision,
                )
              : entry,
        )
        .toList(growable: false);
    if (!entries.any((entry) => entry.id == entryId)) return;
    final operation = ++_operation;
    setState(() {
      _loading = false;
      _saving = true;
      _saveFailed = false;
    });
    try {
      final result = await widget.gateway.save(
        base: base,
        requestId: _requestId(),
        weekStart: plan.weekStart,
        recipes: plan.recipes,
        entries: entries,
      );
      if (operation != _operation) return;
      if (!_authorityCurrent) {
        _retire();
        return;
      }
      setState(() => _snapshot = result);
    } catch (_) {
      if (operation == _operation && !_authorityCurrent) {
        _retire();
      } else if (operation == _operation && _current) {
        setState(() => _saveFailed = true);
      }
    } finally {
      if (operation == _operation && mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _operation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final plan = _current ? _snapshot?.plan : null;
    return CupertinoPageScaffold(
      child: CustomScrollView(
        key: const PageStorageKey('weekly-meal-plan-scroll'),
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.weeklyMealPlanTitle),
          ),
          SliverSafeArea(
            top: false,
            sliver: SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              sliver: plan == null
                  ? SliverFillRemaining(
                      hasScrollBody: false,
                      child: _Status(
                        loading: _loading,
                        failed: _failed,
                        retry: _current ? _load : null,
                      ),
                    )
                  : SliverList.list(
                      children: [
                        if (_saveFailed)
                          Semantics(
                            liveRegion: true,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(l10n.weeklyMealPlanSaveFailed),
                            ),
                          ),
                        ..._days(context, plan),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _days(BuildContext context, WeeklyMealPlan plan) {
    final l10n = AppLocalizations.of(context);
    final start = DateTime.parse(plan.weekStart);
    return List.generate(7, (offset) {
      final day = start.add(Duration(days: offset));
      final date = _dateLabel(context, day);
      final entries =
          plan.entries
              .where((entry) => entry.date == _isoDate(day))
              .toList(growable: false)
            ..sort(
              (left, right) => left.slot.index.compareTo(right.slot.index),
            );
      return CupertinoListSection.insetGrouped(
        key: ValueKey('meal-day-${_isoDate(day)}'),
        header: Text(date),
        children: entries.isEmpty
            ? [CupertinoListTile(title: Text(l10n.weeklyMealPlanEmpty))]
            : entries
                  .map((entry) {
                    final recipe = plan.recipeFor(entry);
                    return Padding(
                      key: ValueKey('meal-entry-${entry.id}'),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            recipe.title,
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_slot(l10n, entry.slot)} · '
                            '${l10n.weeklyMealPlanServings(entry.servings)}',
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .copyWith(
                                  color: CupertinoColors.secondaryLabel
                                      .resolveFrom(context),
                                ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            key: ValueKey('meal-edit-${entry.id}'),
                            height: 48,
                            child: CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              onPressed: !_current || _saving
                                  ? null
                                  : () => _editServings(entry),
                              child: Text(
                                l10n.weeklyMealPlanEditServings,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            key: ValueKey('meal-shopping-${entry.id}'),
                            height: 48,
                            child: CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              onPressed: !_current || _saving
                                  ? null
                                  : () => _showShopping(context, recipe, entry),
                              child: Text(
                                l10n.weeklyMealPlanShoppingPreview,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  })
                  .toList(growable: false),
      );
    });
  }

  Future<void> _showShopping(
    BuildContext context,
    MealRecipe recipe,
    MealPlanEntry entry,
  ) async {
    if (!_current) return;
    final locale = Localizations.localeOf(context).languageCode;
    final summaries = recipe
        .shoppingDraft(entry.servings)
        .shoppingSummaries(locale);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => _ShoppingPreview(
        recipe: recipe,
        servings: entry.servings,
        summaries: summaries,
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({
    required this.loading,
    required this.failed,
    required this.retry,
  });

  final bool loading, failed;
  final Future<void> Function()? retry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading) const CupertinoActivityIndicator(),
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                loading
                    ? l10n.weeklyMealPlanLoading
                    : failed
                    ? l10n.weeklyMealPlanUnavailable
                    : l10n.weeklyMealPlanEmpty,
                textAlign: TextAlign.center,
              ),
            ),
            if (failed) ...[
              const SizedBox(height: 16),
              SizedBox(
                height: 48,
                child: CupertinoButton.filled(
                  key: const ValueKey('weekly-meal-retry'),
                  onPressed: retry == null ? null : () => unawaited(retry!()),
                  child: Text(l10n.weeklyMealPlanRetry),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ShoppingPreview extends StatelessWidget {
  const _ShoppingPreview({
    required this.recipe,
    required this.servings,
    required this.summaries,
  });

  final MealRecipe recipe;
  final int servings;
  final List<String> summaries;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CupertinoPopupSurface(
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 620),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            children: [
              Text(
                recipe.title,
                style: CupertinoTheme.of(context)
                    .textTheme
                    .navLargeTitleTextStyle,
              ),
              const SizedBox(height: 6),
              Text(l10n.weeklyMealPlanServings(servings)),
              const SizedBox(height: 12),
              Text(l10n.weeklyMealPlanShoppingHint),
              const SizedBox(height: 16),
              Semantics(
                container: true,
                label: l10n.weeklyMealPlanIngredients,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: summaries
                      .map(
                        (item) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text('• $item'),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 48,
                child: CupertinoButton.filled(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.weeklyMealPlanClose),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _slot(AppLocalizations l10n, MealSlot slot) => switch (slot) {
  MealSlot.breakfast => l10n.weeklyMealPlanBreakfast,
  MealSlot.lunch => l10n.weeklyMealPlanLunch,
  MealSlot.dinner => l10n.weeklyMealPlanDinner,
  MealSlot.snack => l10n.weeklyMealPlanSnack,
};

String _isoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _dateLabel(BuildContext context, DateTime value) {
  final tr = Localizations.localeOf(context).languageCode == 'tr';
  const en = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const turkish = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];
  final weekday = (tr ? turkish : en)[value.weekday - 1];
  return '$weekday · ${value.day.toString().padLeft(2, '0')}.'
      '${value.month.toString().padLeft(2, '0')}.${value.year}';
}

String _requestId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
