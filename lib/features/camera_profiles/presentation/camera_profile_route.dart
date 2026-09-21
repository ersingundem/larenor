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
import '../data/camera_profile_api.dart';
import '../data/camera_profile_controller.dart';
import 'camera_profile_screen.dart';

const _routeId = '43434343434343434343434343434343';

class CameraProfileRoute extends ConsumerStatefulWidget {
  const CameraProfileRoute({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;
  @override
  ConsumerState<CameraProfileRoute> createState() => _CameraProfileRouteState();
}

class _CameraProfileRouteState extends ConsumerState<CameraProfileRoute> {
  ServerAccountController? _account;
  AppInteractionController? _interaction;
  CoreCameraProfileApi? _api;
  CameraProfileController? _controller;
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
    if (_api != null && !identical(_account?.session, _api?.boundSession)) {
      _retire(showFailure: true);
    }
  }

  void _retire({required bool showFailure}) {
    if (!mounted) return;
    _generation++;
    _api?.retire();
    _controller?.dispose();
    _api = null;
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
    final api = CoreCameraProfileApi(
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
      final controller = CameraProfileController(
        api: api,
        isCurrent: () => _current(generation) && identical(_api, api),
      );
      controller.snapshot = snapshot;
      controller.state = CameraProfileViewState.ready;
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
    final controller = _controller;
    if (controller != null) return CameraProfileScreen(controller: controller);
    return ServiceRootScaffold(
      title: l10n.cameraProfileTitle,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(l10n.cameraProfileStatus),
            footer: Text(l10n.cameraProfilePrivacyBoundary),
            children: [
              if (_loading)
                Semantics(
                  liveRegion: true,
                  label: l10n.cameraProfileLoading,
                  child: const SizedBox(
                    height: 56,
                    child: Center(child: CupertinoActivityIndicator()),
                  ),
                )
              else if (_failed)
                SettingsActionTile(
                  buttonKey: const ValueKey('camera-profile-retry'),
                  leading: const Icon(CupertinoIcons.refresh),
                  title: Text(l10n.cameraProfileReconnect),
                  additionalInfo: Text(l10n.cameraProfileFailed),
                  onTap: _interactive ? _connect : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
