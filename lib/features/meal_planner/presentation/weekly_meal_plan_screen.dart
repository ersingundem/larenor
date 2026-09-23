import 'dart:async';
import 'dart:math';

import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../today/data/today_actions.dart';
import '../../today/domain/today_models.dart';
import '../data/recipe_shopping_handoff.dart';
import '../data/weekly_meal_plan_api.dart';
import '../domain/weekly_meal_plan.dart';

class WeeklyMealPlanScreen extends StatefulWidget {
  const WeeklyMealPlanScreen({
    super.key,
    required this.gateway,
    required this.isCurrent,
    this.onRetire,
    this.shoppingLists = const [],
    this.shoppingActions,
    this.shoppingAuthoritySource,
  });

  final WeeklyMealPlanGateway gateway;
  final bool Function() isCurrent;
  final VoidCallback? onRetire;
  final List<TodayTodoList> shoppingLists;
  final TodayActions? shoppingActions;
  final RecipeShoppingAuthoritySource? shoppingAuthoritySource;

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
  bool _handoffBusy = false;
  bool _handoffFailed = false;
  bool _foreground = true;
  int _operation = 0;
  int _handoffOperation = 0;
  int _ownedOverlayDepth = 0;
  RecipeShoppingReceipt? _handoffReceipt;
  String? _handoffListTitle;

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
      return _ownedOverlayDepth > 0 ||
          (TickerMode.valuesOf(context).enabled &&
              (ModalRoute.of(context)?.isCurrent ?? true));
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
    if (!identical(oldWidget.shoppingActions, widget.shoppingActions)) {
      _handoffOperation++;
      _handoffBusy = false;
      _handoffFailed = false;
      _handoffReceipt = null;
      _handoffListTitle = null;
    }
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
    _handoffOperation++;
    _handoffBusy = false;
    _handoffFailed = false;
    _handoffReceipt = null;
    _handoffListTitle = null;
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

  Future<void> _editEntry(MealPlanEntry entry) async {
    if (_saving || !_current) return;
    final operation = _operation;
    final base = _snapshot;
    if (base?.plan == null ||
        !base!.plan!.entries.any((value) => value.id == entry.id)) {
      return;
    }
    _ownedOverlayDepth++;
    _MealEntryEdit? value;
    ModalRoute<dynamic>? overlayRoute;
    try {
      value = await showCupertinoModalPopup<_MealEntryEdit>(
        context: context,
        builder: (sheetContext) {
          overlayRoute = ModalRoute.of(sheetContext);
          return _MealEntryEditor(
            initialServings: entry.servings,
            initialSlot: entry.slot,
          );
        },
      );
      await overlayRoute?.completed;
    } finally {
      _ownedOverlayDepth--;
    }
    if (value != null && operation == _operation && _current) {
      await _saveEntry(base, entry.id, value);
    }
  }

  Future<void> _saveEntry(
    WeeklyMealPlanSnapshot base,
    String entryId,
    _MealEntryEdit edit,
  ) async {
    final plan = base.plan;
    if (_saving || !_authorityCurrent || plan == null) return;
    final entries = plan.entries
        .map(
          (entry) => entry.id == entryId
              ? MealPlanEntry(
                  id: entry.id,
                  date: entry.date,
                  slot: edit.slot,
                  recipeId: entry.recipeId,
                  servings: edit.servings,
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
    _handoffOperation++;
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
                        if (_handoffBusy)
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: Center(child: CupertinoActivityIndicator()),
                          ),
                        if (_handoffFailed)
                          Semantics(
                            key: const ValueKey('meal-shopping-failure'),
                            liveRegion: true,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(l10n.weeklyMealPlanShoppingFailed),
                            ),
                          ),
                        if (_handoffReceipt != null &&
                            _handoffListTitle != null)
                          Semantics(
                            key: const ValueKey('meal-shopping-success'),
                            liveRegion: true,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                l10n.weeklyMealPlanShoppingSuccess(
                                  _handoffReceipt!.verifiedCount,
                                  _handoffListTitle!,
                                ),
                              ),
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
                              onPressed: !_current || _saving || _handoffBusy
                                  ? null
                                  : () => _editEntry(entry),
                              child: Text(
                                l10n.weeklyMealPlanEditEntry,
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
                              onPressed: !_current || _saving || _handoffBusy
                                  ? null
                                  : () => _showShopping(recipe, entry),
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

  Future<void> _showShopping(MealRecipe recipe, MealPlanEntry entry) async {
    if (!_current) return;
    final operation = _handoffOperation;
    final base = _snapshot;
    final plan = base?.plan;
    if (plan == null || !plan.entries.any((value) => value.id == entry.id)) {
      return;
    }
    final locale = Localizations.localeOf(context).languageCode;
    final summaries = recipe
        .shoppingDraft(entry.servings)
        .shoppingSummaries(locale);
    final lists = _writableLists;
    _ownedOverlayDepth++;
    String? selectedId;
    ModalRoute<dynamic>? previewRoute;
    try {
      selectedId = await showCupertinoModalPopup<String>(
        context: context,
        builder: (sheetContext) {
          previewRoute = ModalRoute.of(sheetContext);
          return _ShoppingPreview(
            recipe: recipe,
            servings: entry.servings,
            summaries: summaries,
            lists: lists,
          );
        },
      );
      await previewRoute?.completed;
    } finally {
      _ownedOverlayDepth--;
    }
    bool flowCurrent() =>
        operation == _handoffOperation &&
        identical(_snapshot, base) &&
        _current;
    if (!mounted || selectedId == null || !flowCurrent()) return;
    final list = _writableLists
        .where((value) => value.entityId == selectedId)
        .firstOrNull;
    if (list == null) return;
    final l10n = AppLocalizations.of(context);
    _ownedOverlayDepth++;
    ModalRoute<dynamic>? confirmationRoute;
    bool? confirmed;
    try {
      confirmed = await showCupertinoDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          confirmationRoute = ModalRoute.of(dialogContext);
          return CupertinoAlertDialog(
            title: Text(l10n.weeklyMealPlanShoppingConfirmTitle),
            content: Text(
              l10n.weeklyMealPlanShoppingConfirmBody(
                summaries.length,
                list.title,
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.weeklyMealPlanCancel),
              ),
              CupertinoDialogAction(
                key: const ValueKey('meal-shopping-confirm'),
                isDefaultAction: true,
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.weeklyMealPlanShoppingConfirm),
              ),
            ],
          );
        },
      );
      await confirmationRoute?.completed;
    } finally {
      _ownedOverlayDepth--;
    }
    if (confirmed == true && flowCurrent()) {
      await _handoff(plan, entry, list, locale);
    }
  }

  List<TodayTodoList> get _writableLists => widget.shoppingLists
      .where(
        (list) =>
            list.available &&
            list.canAdd &&
            list.canSetDescription &&
            list.items.value != null &&
            list.items.issue == null,
      )
      .toList(growable: false);

  bool _listCurrent(TodayTodoList expected) => _writableLists.any(
    (value) =>
        value.entityId == expected.entityId &&
        value.supportedFeatures == expected.supportedFeatures,
  );

  Future<void> _handoff(
    WeeklyMealPlan plan,
    MealPlanEntry entry,
    TodayTodoList list,
    String locale,
  ) async {
    final actions = widget.shoppingActions;
    final source = widget.shoppingAuthoritySource;
    if (_handoffBusy ||
        !_current ||
        actions == null ||
        source == null ||
        !_listCurrent(list)) {
      return;
    }
    RecipeShoppingAuthorityLease? lease;
    try {
      lease = RecipeShoppingAuthorityLease.capture(source);
    } catch (_) {
      lease = null;
    }
    if (lease == null) return;
    final operation = ++_handoffOperation;
    bool valid() =>
        operation == _handoffOperation &&
        identical(widget.shoppingActions, actions) &&
        _current &&
        _listCurrent(list);
    setState(() {
      _handoffBusy = true;
      _handoffFailed = false;
      _handoffReceipt = null;
      _handoffListTitle = null;
    });
    try {
      final receipt = await RecipeShoppingHandoff().addPlanEntry(
        plan: plan,
        entryId: entry.id,
        locale: locale,
        list: list,
        actions: actions,
        authority: lease,
        authoritySource: source,
        visible: valid,
      );
      if (valid()) {
        setState(() {
          _handoffReceipt = receipt;
          _handoffListTitle = list.title;
        });
      }
    } catch (_) {
      if (valid()) setState(() => _handoffFailed = true);
    } finally {
      if (operation == _handoffOperation && mounted) {
        setState(() => _handoffBusy = false);
      }
    }
  }
}

final class _MealEntryEdit {
  const _MealEntryEdit({required this.servings, required this.slot});
  final int servings;
  final MealSlot slot;
}

class _MealEntryEditor extends StatefulWidget {
  const _MealEntryEditor({
    required this.initialServings,
    required this.initialSlot,
  });
  final int initialServings;
  final MealSlot initialSlot;

  @override
  State<_MealEntryEditor> createState() => _MealEntryEditorState();
}

class _MealEntryEditorState extends State<_MealEntryEditor> {
  late final TextEditingController _servings;
  late MealSlot _slot;
  bool _valid = true;

  @override
  void initState() {
    super.initState();
    _servings = TextEditingController(text: '${widget.initialServings}');
    _slot = widget.initialSlot;
  }

  @override
  void dispose() {
    _servings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CupertinoPopupSurface(
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            children: [
              Text(
                l10n.weeklyMealPlanEditEntryTitle,
                style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
              ),
              const SizedBox(height: 16),
              Semantics(
                textField: true,
                label: l10n.weeklyMealPlanServingsLabel,
                child: CupertinoTextField(
                  key: const ValueKey('meal-edit-servings'),
                  controller: _servings,
                  keyboardType: TextInputType.number,
                  onChanged: (text) {
                    final value = int.tryParse(text);
                    setState(
                      () => _valid = value != null && value > 0 && value <= 24,
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Text(l10n.weeklyMealPlanSlotLabel),
              const SizedBox(height: 8),
              for (final slot in MealSlot.values)
                SizedBox(
                  height: 48,
                  child: CupertinoButton(
                    key: ValueKey('meal-edit-slot-${slot.name}'),
                    onPressed: () => setState(() => _slot = slot),
                    child: Row(
                      children: [
                        Icon(
                          _slot == slot
                              ? CupertinoIcons.check_mark_circled_solid
                              : CupertinoIcons.circle,
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(_slotLabel(l10n, slot))),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              SizedBox(
                height: 48,
                child: CupertinoButton.filled(
                  key: const ValueKey('meal-edit-save'),
                  onPressed: !_valid
                      ? null
                      : () => Navigator.of(context).pop(
                          _MealEntryEdit(
                            servings: int.parse(_servings.text),
                            slot: _slot,
                          ),
                        ),
                  child: Text(l10n.weeklyMealPlanSave),
                ),
              ),
            ],
          ),
        ),
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
    required this.recipe,
    required this.servings,
    required this.summaries,
    required this.lists,
  });

  final MealRecipe recipe;
  final int servings;
  final List<String> summaries;
  final List<TodayTodoList> lists;

  @override
  State<_ShoppingPreview> createState() => _ShoppingPreviewState();
}

class _ShoppingPreviewState extends State<_ShoppingPreview> {
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.lists.firstOrNull?.entityId;
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
              if (widget.lists.isEmpty)
                Semantics(
                  key: const ValueKey('meal-shopping-unavailable'),
                  liveRegion: true,
                  child: Text(l10n.weeklyMealPlanShoppingNoWritableList),
                )
              else ...[
                Text(l10n.weeklyMealPlanShoppingChooseList),
                const SizedBox(height: 8),
                for (final list in widget.lists)
                  SizedBox(
                    height: 48,
                    child: CupertinoButton(
                      key: ValueKey('meal-shopping-list-${list.entityId}'),
                      onPressed: () =>
                          setState(() => _selected = list.entityId),
                      child: Row(
                        children: [
                          Icon(
                            _selected == list.entityId
                                ? CupertinoIcons.check_mark_circled_solid
                                : CupertinoIcons.circle,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              list.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 48,
                  child: CupertinoButton.filled(
                    key: const ValueKey('meal-shopping-review'),
                    onPressed: _selected == null
                        ? null
                        : () => Navigator.of(context).pop(_selected),
                    child: Text(l10n.weeklyMealPlanShoppingReview),
                  ),
                ),
                const SizedBox(height: 12),
              ],
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

String _slotLabel(AppLocalizations l10n, MealSlot slot) => _slot(l10n, slot);

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
