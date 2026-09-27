import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../core/home_session_controller.dart';
import '../../../../core/home_source_store.dart';
import '../data/server_party_dj_controller.dart';
import 'server_party_dj_screen.dart';

final class ServerPartyDjRoute extends ConsumerStatefulWidget {
  const ServerPartyDjRoute({this.installationId, super.key});

  static const path = '/media/party-dj';
  final String? installationId;

  @override
  ConsumerState<ServerPartyDjRoute> createState() => _ServerPartyDjRouteState();
}

final class _ServerPartyDjRouteState extends ConsumerState<ServerPartyDjRoute> {
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _generation, _homeEpoch;
  ServerPartyDjController? _controller;
  Timer? _heartbeat;
  bool _setupRequested = false;

  bool _bindingCurrent() {
    final home = _home;
    return mounted &&
        home != null &&
        identical(ref.read(homeSessionControllerProvider), home) &&
        identical(home.runtimeIdentity, _identity) &&
        home.account.generation == _generation &&
        home.interaction.epoch == _homeEpoch;
  }

  bool _current() {
    if (!_sessionUsable()) return false;
    return (_interaction?.active ?? true) &&
        _home!.interaction.active &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
  }

  bool _sessionUsable() {
    if (!_bindingCurrent()) return false;
    final home = _home!;
    final session = home.account.session;
    return home.source == HomeSource.verifiedCore &&
        !home.busy &&
        home.failure == null &&
        session?.context != null &&
        session?.sessionFamilyId != null &&
        session?.authMutationPending == false &&
        session?.user.mustChangePassword == false;
  }

  void _changed() {
    if (!mounted) return;
    if (!_sessionUsable()) {
      _heartbeat?.cancel();
      _heartbeat = null;
      _controller?.removeListener(_controllerChanged);
      _controller?.dispose();
      _controller = null;
      _setupRequested = false;
    } else if (!_current()) {
      _heartbeat?.cancel();
      _heartbeat = null;
      _controller?.suspend();
      _setupRequested = false;
    } else {
      _ensureController();
      _requestSetup();
    }
    setState(() {});
  }

  void _controllerChanged() {
    if (!mounted) return;
    final hasRoom = _controller?.room != null;
    if (hasRoom && _heartbeat == null && _current()) {
      _heartbeat = Timer.periodic(const Duration(seconds: 12), (_) {
        if (_current()) {
          _controller?.heartbeat(current: _current);
        }
      });
    } else if (!hasRoom || !_current()) {
      _heartbeat?.cancel();
      _heartbeat = null;
    }
  }

  void _ensureController() {
    if (_controller != null || !_current()) return;
    final value = ServerPartyDjController(
      _home!.account,
      installationId: widget.installationId,
    );
    value.addListener(_controllerChanged);
    _controller = value;
  }

  void _requestSetup() {
    if (_setupRequested || _controller == null || !_current()) return;
    _setupRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current()) _controller?.resume(current: _current);
    });
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
      _homeEpoch = home.interaction.epoch;
      home.addListener(_changed);
    }
    if (!identical(_interaction, interaction)) {
      _interaction?.removeListener(_changed);
      _interaction = interaction;
      interaction?.addListener(_changed);
    }
    _ensureController();
    _requestSetup();
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _interaction?.removeListener(_changed);
    _home?.removeListener(_changed);
    _controller?.removeListener(_controllerChanged);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(
            Localizations.localeOf(context).languageCode == 'tr'
                ? 'Parti DJ'
                : 'Party DJ',
          ),
        ),
        child: const Center(child: CupertinoActivityIndicator()),
      );
    }
    return ServerPartyDjScreen(
      controller: controller,
      current: _current,
      turkish: Localizations.localeOf(context).languageCode == 'tr',
    );
  }
}
