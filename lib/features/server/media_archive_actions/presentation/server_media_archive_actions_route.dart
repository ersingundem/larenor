import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../core/home_session_controller.dart';
import '../../../../core/home_source_store.dart';
import '../data/server_media_archive_actions_controller.dart';
import 'server_media_archive_actions_screen.dart';

final class ServerMediaArchiveActionsRoute extends ConsumerStatefulWidget {
  const ServerMediaArchiveActionsRoute({
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
    super.key,
  });

  static const path = '/media/archive-actions';
  final String installationId;
  final int installationRevision, snapshotRevision;

  @override
  ConsumerState<ServerMediaArchiveActionsRoute> createState() =>
      _ServerMediaArchiveActionsRouteState();
}

final class _ServerMediaArchiveActionsRouteState
    extends ConsumerState<ServerMediaArchiveActionsRoute> {
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _generation, _homeEpoch;
  ServerMediaArchiveActionsController? _controller;
  Timer? _jobRefresh;
  bool _requested = false;

  bool _bindingCurrent() {
    final home = _home;
    return mounted &&
        home != null &&
        identical(ref.read(homeSessionControllerProvider), home) &&
        identical(home.runtimeIdentity, _identity) &&
        home.account.generation == _generation &&
        home.interaction.epoch == _homeEpoch;
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
        session?.user.mustChangePassword == false &&
        session?.user.canAdminister == true;
  }

  bool _current() =>
      _sessionUsable() &&
      (_interaction?.active ?? true) &&
      _home!.interaction.active &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _changed() {
    if (!mounted) return;
    if (!_sessionUsable()) {
      _retireController();
    } else if (!_current()) {
      _jobRefresh?.cancel();
      _jobRefresh = null;
      _controller?.invalidate();
      _requested = false;
    } else {
      _ensureController();
      _requestLoad();
    }
    setState(() {});
  }

  void _controllerChanged() {
    if (!mounted) return;
    final hasActive =
        _controller?.snapshot?.jobs.any((job) => job.active) ?? false;
    if (hasActive && _jobRefresh == null && _current()) {
      _jobRefresh = Timer.periodic(const Duration(seconds: 8), (_) {
        if (!_current() || _controller?.busy == true) return;
        final jobs = _controller?.snapshot?.jobs.where((job) => job.active);
        if (jobs != null && jobs.isNotEmpty) {
          unawaited(_controller?.refreshJob(jobs.first, current: _current));
        }
      });
    } else if (!hasActive || !_current()) {
      _jobRefresh?.cancel();
      _jobRefresh = null;
    }
  }

  void _ensureController() {
    if (_controller != null || !_current()) return;
    final value = ServerMediaArchiveActionsController(
      _home!.account,
      installationId: widget.installationId,
      installationRevision: widget.installationRevision,
      snapshotRevision: widget.snapshotRevision,
    );
    value.addListener(_controllerChanged);
    _controller = value;
  }

  void _requestLoad() {
    if (_requested || _controller == null || !_current()) return;
    _requested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current()) unawaited(_controller?.load(current: _current));
    });
  }

  void _retireController() {
    _jobRefresh?.cancel();
    _jobRefresh = null;
    _controller?.removeListener(_controllerChanged);
    _controller?.dispose();
    _controller = null;
    _requested = false;
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
    _requestLoad();
  }

  @override
  void dispose() {
    _jobRefresh?.cancel();
    _interaction?.removeListener(_changed);
    _home?.removeListener(_changed);
    _controller?.removeListener(_controllerChanged);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final turkish = Localizations.localeOf(context).languageCode == 'tr';
    if (controller == null) {
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(turkish ? 'Arşiv işlemleri' : 'Archive actions'),
        ),
        child: const Center(child: CupertinoActivityIndicator()),
      );
    }
    return ServerMediaArchiveActionsScreen(
      controller: controller,
      current: _current,
      turkish: turkish,
    );
  }
}
