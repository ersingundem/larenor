import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/providers/server_providers.dart';
import '../data/kiosk_remote_api.dart';
import '../data/kiosk_remote_controller.dart';
import '../runtime/managed_tablet_runtime_scope.dart';
import 'kiosk_remote_screen.dart';

class KioskRemoteRoute extends ConsumerStatefulWidget {
  const KioskRemoteRoute({super.key});
  @override
  ConsumerState<KioskRemoteRoute> createState() => _KioskRemoteRouteState();
}

class _KioskRemoteRouteState extends ConsumerState<KioskRemoteRoute> {
  ServerAccountController? _account;
  AppInteractionController? _interaction;
  CoreKioskRemoteApi? _api;
  KioskRemoteController? _controller;
  int _generation = 0;
  bool get _active => _interaction?.active ?? true;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _account!.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
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
      _active &&
      ModalRoute.of(context)?.isCurrent == true;

  void _interactionChanged() {
    if (!_active) {
      _retire();
    } else if (_controller == null) {
      _connect();
    }
  }

  void _accountChanged() {
    if (_api != null && !identical(_account?.session, _api?.boundSession)) {
      _retire();
    }
  }

  void _retire() {
    if (!mounted) return;
    _generation++;
    _controller?.dispose();
    _controller = null;
    _api = null;
    setState(() {});
  }

  void _connect() {
    if (!mounted || !_active || _controller != null) return;
    final generation = ++_generation;
    final api = CoreKioskRemoteApi(
      account: _account!,
      sessionRevision: generation,
      routeRevision: generation,
      isCurrent: () => _current(generation),
    );
    _api = api;
    setState(() {
      _controller = KioskRemoteController(
        api: api,
        isCurrent: () => _current(generation) && identical(_api, api),
        onPairingRevoked: ref.read(managedTabletRuntimeOwnerProvider).revoke,
      );
    });
  }

  @override
  void dispose() {
    _generation++;
    _interaction?.removeListener(_interactionChanged);
    _account?.removeListener(_accountChanged);
    _controller?.dispose();
    _api?.retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller case final controller?) {
      return KioskRemoteScreen(controller: controller);
    }
    return ServiceRootScaffold(
      title: AppLocalizations.of(context).kioskRemoteTitle,
      slivers: const [
        SliverFillRemaining(child: Center(child: CupertinoActivityIndicator())),
      ],
    );
  }
}
