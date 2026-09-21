import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../server/data/server_account_controller.dart';
import '../../today/domain/today_models.dart';
import '../../today/presentation/today_support.dart';
import '../../today/providers/today_providers.dart';
import '../data/recipe_shopping_handoff.dart';
import '../data/weekly_meal_plan_api.dart';
import '../data/weekly_meal_shopping_gateway.dart';
import 'weekly_meal_plan_screen.dart';

class WeeklyMealPlanRoute extends ConsumerStatefulWidget {
  const WeeklyMealPlanRoute({super.key, this.apiFactory});

  final ServerApiFactory? apiFactory;

  @override
  ConsumerState<WeeklyMealPlanRoute> createState() =>
      _WeeklyMealPlanRouteState();
}

class _WeeklyMealPlanRouteState extends ConsumerState<WeeklyMealPlanRoute> {
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _generation, _interactionEpoch;
  WeeklyMealPlanAccountGateway? _gateway;

  bool _bindingCurrent() {
    final home = _home;
    if (!mounted || home == null) return false;
    return identical(ref.read(homeSessionControllerProvider), home) &&
        identical(home.runtimeIdentity, _identity) &&
        home.account.generation == _generation &&
        home.interaction.epoch == _interactionEpoch;
  }

  bool _current() {
    if (!_bindingCurrent()) return false;
    final home = _home!;
    final session = home.account.session;
    return (_interaction?.active ?? true) &&
        home.source == HomeSource.verifiedCore &&
        !home.busy &&
        home.failure == null &&
        home.interaction.active &&
        session?.context != null &&
        session!.user.mustChangePassword == false &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
  }

  void _changed() {
    if (!mounted) return;
    final home = _home;
    final session = home?.account.session;
    if (!_bindingCurrent() ||
        home?.source != HomeSource.verifiedCore ||
        session?.context == null ||
        session?.user.mustChangePassword != false) {
      _gateway?.close();
      _gateway = null;
    }
    setState(() {});
  }

  TodayTodoList? _shoppingList(TodaySnapshot? snapshot) {
    if (snapshot == null) return null;
    for (final id in const ['todo.shopping_list', 'todo.shopping']) {
      for (final list in snapshot.todoLists) {
        if (list.entityId == id &&
            list.canAdd &&
            todayListWritable(snapshot, list)) {
          return list;
        }
      }
    }
    return null;
  }

  WeeklyMealShoppingGateway? _shoppingGateway() {
    final snapshot = ref.watch(todayProvider).value;
    final actions = ref.watch(todayActionsProvider);
    final list = _shoppingList(snapshot);
    final home = _home;
    if (actions == null || list == null || home == null) return null;
    return VerifiedWeeklyMealShoppingGateway(
      list: list,
      actions: actions,
      authoritySource: HomeRecipeShoppingAuthoritySource(home),
      listCurrent: () {
        if (!_bindingCurrent() ||
            !identical(ref.read(todayActionsProvider), actions)) {
          return false;
        }
        final latest = ref.read(todayProvider).value;
        final current = _shoppingList(latest);
        return current != null &&
            current.entityId == list.entityId &&
            current.title == list.title &&
            current.supportedFeatures == list.supportedFeatures;
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final home = ref.read(homeSessionControllerProvider);
    final interaction = AppInteractionScope.maybeOf(context);
    if (_home == null && home != null) {
      _home = home;
      _identity = home.runtimeIdentity;
      _generation = home.account.generation;
      _interactionEpoch = home.interaction.epoch;
      home.addListener(_changed);
    }
    if (!identical(_interaction, interaction)) {
      _interaction?.removeListener(_changed);
      _interaction = interaction;
      interaction?.addListener(_changed);
    }
    if (_gateway == null && _current()) {
      _gateway = WeeklyMealPlanAccountGateway(
        account: _home!.account,
        context: _home!.account.session!.context!,
        isCurrent: _current,
        apiFactory: widget.apiFactory,
      );
    }
  }

  @override
  void dispose() {
    _interaction?.removeListener(_changed);
    _home?.removeListener(_changed);
    _gateway?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    final gateway = _gateway;
    if (gateway != null && _current()) {
      return WeeklyMealPlanScreen(
        gateway: gateway,
        shoppingGateway: _shoppingGateway(),
        isCurrent: _current,
      );
    }
    final l10n = AppLocalizations.of(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.weeklyMealPlanTitle),
      ),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Semantics(
              liveRegion: true,
              child: Text(
                l10n.weeklyMealPlanUnavailable,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
