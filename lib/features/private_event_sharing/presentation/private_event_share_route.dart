import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../server/domain/server_models.dart';
import '../data/private_event_share_account_api.dart';
import '../data/private_event_share_controller.dart';
import 'private_event_share_screen.dart';

final class PrivateEventShareRoute extends ConsumerStatefulWidget {
  const PrivateEventShareRoute({
    super.key,
    required this.cameraId,
    required this.eventId,
    this.downloadAdapter,
    required this.commandIds,
  });

  final String cameraId, eventId;
  final PrivateEventDownloadAdapter? downloadAdapter;
  final String Function() commandIds;

  @override
  ConsumerState<PrivateEventShareRoute> createState() =>
      _PrivateEventShareRouteState();
}

class _PrivateEventShareRouteState
    extends ConsumerState<PrivateEventShareRoute> {
  HomeSessionController? _home;
  Object? _runtimeIdentity;
  int? _generation;
  ServerSession? _session;
  PrivateEventShareAccountApi? _api;
  PrivateEventShareController? _controller;
  bool _loading = false;
  String? _failure;

  bool _currentFor(ServerSession session) {
    final home = _home;
    if (!mounted || home == null) return false;
    try {
      return identical(ref.read(homeSessionControllerProvider), home) &&
          identical(home.runtimeIdentity, _runtimeIdentity) &&
          home.account.generation == _generation &&
          identical(home.account.session, session) &&
          home.source == HomeSource.verifiedCore &&
          !home.busy &&
          home.failure == null &&
          session.context != null &&
          !session.user.mustChangePassword &&
          ModalRoute.of(context)?.isCurrent == true;
    } catch (_) {
      return false;
    }
  }

  void _changed() {
    if (!mounted) return;
    final session = _session;
    if (session != null && !_currentFor(session)) _retire();
    if (_controller == null && !_loading) unawaited(_load());
    setState(() {});
  }

  void _retire() {
    _api?.retire();
    _controller?.cancel();
    _api = null;
    _controller = null;
    _session = null;
  }

  Future<void> _load() async {
    final home = _home;
    if (_loading || home == null || home.source != HomeSource.verifiedCore) {
      return;
    }
    _loading = true;
    if (mounted) setState(() {});
    try {
      final loaded = await home.account.withSession((api, session) async {
        _session = session;
        if (!_currentFor(session)) {
          throw const LarenorServerException('cancelled');
        }
        final gateway = PrivateEventShareAccountApi(
          api,
          session,
          cameraId: widget.cameraId,
          eventId: widget.eventId,
          isCurrent: () => _currentFor(session),
          downloadAdapter: widget.downloadAdapter,
        );
        return (gateway: gateway, session: session);
      });
      if (!_currentFor(loaded.session)) {
        loaded.gateway.retire();
        return;
      }
      _api = loaded.gateway;
      _controller = PrivateEventShareController(
        loaded.gateway,
        commandIds: widget.commandIds,
      );
      _failure = null;
    } catch (_) {
      _retire();
      _failure = 'Private event sharing is unavailable';
    } finally {
      _loading = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final home = ref.read(homeSessionControllerProvider);
    if (_home == null) {
      _home = home;
      _runtimeIdentity = home?.runtimeIdentity;
      _generation = home?.account.generation;
      home?.addListener(_changed);
      unawaited(_load());
    } else if (!identical(_home, home)) {
      _retire();
      _failure = 'Private event sharing is unavailable';
    }
  }

  @override
  void dispose() {
    _home?.removeListener(_changed);
    _retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null) {
      return PrivateEventShareScreen(controller: controller);
    }
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Private event sharing'),
      ),
      child: SafeArea(
        child: Center(
          child: Text(_failure ?? (_loading ? 'Loading' : 'Unavailable')),
        ),
      ),
    );
  }
}
