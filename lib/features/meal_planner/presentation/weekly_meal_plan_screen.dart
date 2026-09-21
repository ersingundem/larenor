import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/weekly_meal_plan_api.dart';
import '../data/weekly_meal_shopping_gateway.dart';
import '../domain/recipe_shopping_draft.dart';
import '../domain/weekly_meal_plan.dart';

class WeeklyMealPlanScreen extends StatefulWidget {
  const WeeklyMealPlanScreen({
    super.key,
    required this.gateway,
    required this.isCurrent,
    this.shoppingGateway,
    this.onRetire,
  });

  final WeeklyMealPlanGateway gateway;
  final WeeklyMealShoppingGateway? shoppingGateway;
  final bool Function() isCurrent;
  final VoidCallback? onRetire;

  @override
  State<WeeklyMealPlanScreen> createState() => _WeeklyMealPlanScreenState();
}

class _WeeklyMealPlanScreenState extends State<WeeklyMealPlanScreen>
    with WidgetsBindingObserver {
  WeeklyMealPlanSnapshot? _snapshot;
  bool _loading = false;
  bool _failed = false;
  bool _foreground = true;
  int _operation = 0;

  bool get _current =>
      mounted &&
      _foreground &&
      widget.isCurrent() &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

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

  void _retire() {
    _operation++;
    _snapshot = null;
    _loading = false;
    _failed = false;
    widget.onRetire?.call();
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (_loading || !_current) return;
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _operation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final plan = _snapshot?.plan;
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
                  : SliverList.list(children: _days(context, plan)),
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
                            key: ValueKey('meal-shopping-${entry.id}'),
                            height: 48,
                            child: CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              onPressed: !_current
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
        plan: _snapshot!.plan!,
        entry: entry,
        recipe: recipe,
        servings: entry.servings,
        summaries: summaries,
        gateway: widget.shoppingGateway,
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

class _ShoppingPreview extends StatefulWidget {
  const _ShoppingPreview({
    required this.plan,
    required this.entry,
    required this.recipe,
    required this.servings,
    required this.summaries,
    required this.gateway,
  });

  final WeeklyMealPlan plan;
  final MealPlanEntry entry;
  final MealRecipe recipe;
  final int servings;
  final List<String> summaries;
  final WeeklyMealShoppingGateway? gateway;

  @override
  State<_ShoppingPreview> createState() => _ShoppingPreviewState();
}

class _ShoppingPreviewState extends State<_ShoppingPreview>
    with WidgetsBindingObserver {
  bool _busy = false;
  bool _foreground = true;
  bool _success = false;
  int _operation = 0;
  String? _status;

  bool get _visible =>
      mounted &&
      _foreground &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _operation++;
      _busy = false;
      _status = null;
      _success = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _add() async {
    final gateway = widget.gateway;
    if (_busy || gateway == null || !_visible) return;
    final operation = ++_operation;
    final locale = Localizations.localeOf(context).languageCode;
    setState(() {
      _busy = true;
      _status = null;
      _success = false;
    });
    try {
      final count = await gateway.add(
        plan: widget.plan,
        entry: widget.entry,
        locale: locale,
        visible: () => operation == _operation && _visible,
      );
      if (operation == _operation && _visible) {
        setState(() {
          _success = true;
          _status = AppLocalizations.of(context)
              .weeklyMealPlanShoppingAdded(count, gateway.listTitle);
        });
      }
    } on RecipeShoppingException catch (error) {
      if (operation == _operation && _visible) {
        setState(() {
          _success = false;
          _status = error.code == 'stale_authority'
              ? AppLocalizations.of(context).weeklyMealPlanShoppingChanged
              : AppLocalizations.of(context).weeklyMealPlanShoppingUnavailable;
        });
      }
    } catch (_) {
      if (operation == _operation && _visible) {
        setState(() {
          _success = false;
          _status = AppLocalizations.of(context)
              .weeklyMealPlanShoppingUnavailable;
        });
      }
    } finally {
      if (operation == _operation && mounted) {
        setState(() => _busy = false);
      }
    }
  }

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
                widget.recipe.title,
                style: CupertinoTheme.of(context)
                    .textTheme
                    .navLargeTitleTextStyle,
              ),
              const SizedBox(height: 6),
              Text(l10n.weeklyMealPlanServings(widget.servings)),
              const SizedBox(height: 12),
              Text(l10n.weeklyMealPlanShoppingHint),
              const SizedBox(height: 16),
              Semantics(
                container: true,
                label: l10n.weeklyMealPlanIngredients,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.summaries
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
              if (widget.gateway == null)
                Text(
                  l10n.weeklyMealPlanShoppingUnavailable,
                  key: const ValueKey('meal-shopping-unavailable'),
                  textAlign: TextAlign.center,
                )
              else
                SizedBox(
                  height: 48,
                  child: CupertinoButton.filled(
                    key: const ValueKey('meal-shopping-add'),
                    onPressed: _busy ? null : _add,
                    child: _busy
                        ? Semantics(
                            liveRegion: true,
                            label: l10n.weeklyMealPlanShoppingAdding,
                            child: const CupertinoActivityIndicator(),
                          )
                        : Text(l10n.weeklyMealPlanShoppingAdd),
                  ),
                ),
              if (_status != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  key: const ValueKey('meal-shopping-status'),
                  liveRegion: true,
                  child: Text(
                    _status!,
                    textAlign: TextAlign.center,
                    style: _success
                        ? const TextStyle(fontWeight: FontWeight.w600)
                        : null,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                child: CupertinoButton.filled(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(l10n.weeklyMealPlanClose),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _operation++;
    super.dispose();
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
