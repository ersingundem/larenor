import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/providers/server_providers.dart';
import '../data/mesh_center_management_api.dart';
import '../data/mesh_center_management_controller.dart';
import 'mesh_center_management_screen.dart';

const _routeId = '55555555555555555555555555555556';

class MeshCenterRoute extends ConsumerStatefulWidget {
  const MeshCenterRoute({super.key, required this.gateCurrent});

  final bool Function() gateCurrent;

  @override
  ConsumerState<MeshCenterRoute> createState() => _MeshCenterRouteState();
}

class _MeshCenterRouteState extends ConsumerState<MeshCenterRoute> {
  ServerAccountController? _account;
  AppInteractionController? _interaction;
  CoreMeshCenterManagementApi? _api;
  MeshCenterManagementController? _controller;
  int _generation = 0;
  bool _loading = true;
  bool _failed = false;

  bool get _interactive => _interaction?.active ?? true;

  @override
  void initState() {
    super.initState();
    final account = ref.read(serverAccountControllerProvider);
    _account = account;
    account.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_connect()));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (identical(next, _interaction)) return;
    _interaction?.removeListener(_interactionChanged);
    _interaction = next;
    next?.addListener(_interactionChanged);
  }

  bool _current(int generation) {
    if (!mounted || generation != _generation || !_interactive) return false;
    try {
      return widget.gateCurrent() && ModalRoute.of(context)?.isCurrent == true;
    } catch (_) {
      return false;
    }
  }

  void _interactionChanged() {
    if (!_interactive) _retire(showFailure: true);
  }

  void _accountChanged() {
    final api = _api;
    if (api != null && !identical(_account?.session, api.boundSession)) {
      _retire(showFailure: true);
    }
  }

  void _retire({required bool showFailure}) {
    if (!mounted) return;
    _generation++;
    _api?.retire();
    _api = null;
    _controller?.dispose();
    _controller = null;
    setState(() {
      _loading = false;
      _failed = showFailure;
    });
  }

  Future<void> _connect() async {
    if (!_interactive) {
      _retire(showFailure: true);
      return;
    }
    final generation = ++_generation;
    _api?.retire();
    _controller?.dispose();
    _controller = null;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final api = CoreMeshCenterManagementApi(
      account: _account!,
      routeId: _routeId,
      sessionRevision: generation,
      routeRevision: generation,
      isCurrent: () => _current(generation),
    );
    _api = api;
    try {
      final snapshot = await api.bootstrap();
      if (!_current(generation) || !identical(_api, api)) {
        api.retire();
        return;
      }
      final controller = MeshCenterManagementController(
        api: api,
        authority: snapshot.authority,
        isCurrent: () => _current(generation) && identical(_api, api),
      );
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
    final tr = Localizations.localeOf(context).languageCode == 'tr';
    final controller = _controller;
    if (controller != null) {
      return MeshCenterManagementScreen(controller: controller);
    }
    return ServiceRootScaffold(
      title: tr ? 'Zigbee ve Thread ağı' : 'Zigbee and Thread mesh',
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(tr ? 'Core bağlantısı' : 'Core connection'),
            footer: Text(
              tr
                  ? 'Yalnız doğrulanmış yönetici oturumu ve açık ayar rotası ağ yönetimine erişebilir.'
                  : 'Only a verified admin session and this active settings route can access mesh management.',
            ),
            children: [
              if (_loading)
                Semantics(
                  liveRegion: true,
                  label: tr ? 'Ağ merkezi yükleniyor' : 'Loading mesh center',
                  child: const SizedBox(
                    height: 56,
                    child: Center(child: CupertinoActivityIndicator()),
                  ),
                )
              else if (_failed)
                SettingsActionTile(
                  buttonKey: const ValueKey('mesh-center-route-retry'),
                  leading: const Icon(CupertinoIcons.refresh),
                  title: Text(tr ? 'Yeniden bağlan' : 'Reconnect'),
                  additionalInfo: Text(
                    tr ? 'Core, hesap, oturum veya rota doğrulanamadı.' : 'Core, account, session, or route could not be verified.',
                  ),
                  onTap: _interactive ? _connect : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
