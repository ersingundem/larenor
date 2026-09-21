import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/providers/server_providers.dart';
import '../data/core_energy_priority_api.dart';
import '../data/energy_priority_controller.dart';
import 'energy_priority_screen.dart';

class EnergyPriorityRoute extends ConsumerStatefulWidget {
  const EnergyPriorityRoute({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;
  @override
  ConsumerState<EnergyPriorityRoute> createState() =>
      _EnergyPriorityRouteState();
}

class _EnergyPriorityRouteState extends ConsumerState<EnergyPriorityRoute> {
  ServerAccountController? _account;
  AppInteractionController? _interaction;
  CoreEnergyPriorityApi? _api;
  EnergyPriorityController? _controller;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider)
      ?..addListener(_accountChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (identical(next, _interaction)) return;
    _interaction?.removeListener(_interactionChanged);
    _interaction = next?..addListener(_interactionChanged);
    _interactionChanged();
  }

  bool _current(int generation) {
    if (!mounted ||
        generation != _generation ||
        !(_interaction?.active ?? true)) {
      return false;
    }
    try {
      return widget.gateCurrent() && ModalRoute.of(context)?.isCurrent == true;
    } catch (_) {
      return false;
    }
  }

  void _interactionChanged() {
    if (!(_interaction?.active ?? true)) {
      _retire();
    } else if (_controller == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller == null) _connect();
      });
    }
  }

  void _accountChanged() {
    if (_api case final api?
        when !identical(_account?.session, api.boundSession)) {
      _retire();
    }
    if (_controller == null && _account?.session?.context != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller == null) _connect();
      });
    }
  }

  void _retire() {
    if (!mounted) return;
    _generation++;
    _api?.retire();
    _controller?.dispose();
    _api = null;
    _controller = null;
    setState(() {});
  }

  void _connect() {
    final account = _account;
    if (account == null || account.session?.context == null) return;
    final generation = ++_generation;
    final api = CoreEnergyPriorityApi(
      account: account,
      isCurrent: () => _current(generation),
    );
    _api = api;
    setState(() {
      _controller = EnergyPriorityController(
        api: api,
        isCurrent: () => _current(generation) && identical(_api, api),
      );
    });
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
    final controller = _controller;
    if (controller != null) return EnergyPriorityScreen(controller: controller);
    final tr = Localizations.localeOf(context).languageCode == 'tr';
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(tr ? 'Güneş ve batarya' : 'Solar and battery'),
      ),
      child: Center(
        child: CupertinoButton(
          minimumSize: const Size(48, 48),
          onPressed: _connect,
          child: Text(tr ? 'Core’a bağlan' : 'Connect to Core'),
        ),
      ),
    );
  }
}
