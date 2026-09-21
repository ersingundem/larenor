import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/providers/server_providers.dart';
import '../data/irrigation_budget_api.dart';
import '../data/irrigation_budget_controller.dart';
import 'irrigation_budget_screen.dart';

const _routeId = '49494949494949494949494949494949';

class IrrigationBudgetRoute extends ConsumerStatefulWidget {
  const IrrigationBudgetRoute({super.key});
  @override
  ConsumerState<IrrigationBudgetRoute> createState() =>
      _IrrigationBudgetRouteState();
}

class _IrrigationBudgetRouteState extends ConsumerState<IrrigationBudgetRoute> {
  ServerAccountController? _account;
  AppInteractionController? _interaction;
  CoreIrrigationBudgetApi? _api;
  IrrigationBudgetController? _controller;
  int _generation = 0;
  bool _loading = true, _failed = false;
  bool get _interactive => _interaction?.active ?? true;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _account!.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_connect()));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (identical(next, _interaction)) return;
    _interaction?.removeListener(_interactionChanged);
    _interaction = next?..addListener(_interactionChanged);
  }

  bool _current(int generation) =>
      mounted &&
      generation == _generation &&
      _interactive &&
      ModalRoute.of(context)?.isCurrent == true;

  void _interactionChanged() {
    if (!_interactive) _retire();
  }

  void _accountChanged() {
    if (_api != null && !identical(_account?.session, _api?.boundSession))
      _retire();
  }

  void _retire() {
    if (!mounted) return;
    _generation++;
    _api?.retire();
    _controller?.dispose();
    _api = null;
    _controller = null;
    setState(() {
      _loading = false;
      _failed = true;
    });
  }

  Future<void> _connect() async {
    if (!_interactive) return _retire();
    final generation = ++_generation;
    _api?.retire();
    _controller?.dispose();
    setState(() {
      _loading = true;
      _failed = false;
    });
    final api = CoreIrrigationBudgetApi(
      account: _account!,
      routeId: _routeId,
      sessionRevision: generation,
      routeRevision: generation,
      isCurrent: () => _current(generation),
    );
    _api = api;
    try {
      final snapshot = await api.load();
      if (!_current(generation) || !identical(_api, api)) return api.retire();
      final controller =
          IrrigationBudgetController(
              api: api,
              isCurrent: () => _current(generation) && identical(_api, api),
            )
            ..snapshot = snapshot
            ..state = IrrigationBudgetViewState.ready;
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (_) {
      if (_current(generation) && identical(_api, api)) {
        api.retire();
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _interaction?.removeListener(_interactionChanged);
    _account?.removeListener(_accountChanged);
    _api?.retire();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_controller case final controller?)
      return IrrigationBudgetScreen(controller: controller);
    return ServiceRootScaffold(
      title: l10n.irrigationBudgetTitle,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(l10n.irrigationBudgetStatus),
            footer: Text(l10n.irrigationBudgetManualBoundary),
            children: [
              if (_loading)
                Semantics(
                  liveRegion: true,
                  label: l10n.irrigationBudgetLoading,
                  child: const SizedBox(
                    height: 56,
                    child: Center(child: CupertinoActivityIndicator()),
                  ),
                )
              else if (_failed)
                SettingsActionTile(
                  buttonKey: const ValueKey('irrigation-budget-reconnect'),
                  leading: const Icon(CupertinoIcons.refresh),
                  title: Text(l10n.irrigationBudgetRefresh),
                  additionalInfo: Text(l10n.irrigationBudgetFailed),
                  onTap: _interactive ? _connect : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
