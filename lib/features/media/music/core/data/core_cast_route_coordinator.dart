import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/core_music_target_models.dart';
import 'core_cast_route_bridge.dart';
import 'core_music_targets_controller.dart';

class CoreCastRouteBinding {
  const CoreCastRouteBinding({required this.route, required this.coreTargetId});
  final CoreCastRoute route;
  final String? coreTargetId;
  bool get selectable => route.available && coreTargetId != null;
}

/// Advisory Google Cast discovery. Playback remains owned by the exact,
/// revision-bound Music Assistant target in Larenor Core.
class CoreCastRouteCoordinator extends ChangeNotifier {
  CoreCastRouteCoordinator({required this.core, required this.platform}) {
    core.addListener(_coreChanged);
    _subscription = platform.snapshots.listen(
      _snapshot,
      onError: (_) => _fail('invalid_response'),
    );
  }

  final CoreMusicTargetsController core;
  final CoreCastRoutePlatform platform;
  late final StreamSubscription<CoreCastRouteSnapshot> _subscription;
  CoreCastRouteSnapshot? _native;
  String? _selectedRouteId;
  bool _disposed = false;
  bool active = false;
  bool busy = false;
  String? failure;
  List<CoreCastRouteBinding> routes = const [];

  bool get supported => platform.supported;

  Future<void> start() async {
    if (_disposed || active || busy || !supported) return;
    busy = true;
    active = true;
    failure = null;
    notifyListeners();
    try {
      await platform.start();
      if (_disposed) return;
    } catch (error) {
      if (_disposed) return;
      active = false;
      failure = error is CoreCastRouteException ? error.code : 'unavailable';
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> stop() async {
    if (_disposed || !active) return;
    active = false;
    _native = null;
    routes = const [];
    try {
      await platform.stop();
    } catch (_) {
      // Removing an already retired discovery callback is the safe state.
    }
    if (!_disposed) notifyListeners();
  }

  bool select(String routeId) {
    if (_disposed || !active || !core.isAuthorized) return false;
    final matches = routes.where(
      (item) => item.route.id == routeId && item.selectable,
    );
    if (matches.length != 1) return false;
    final targetId = matches.single.coreTargetId!;
    core.select(targetId);
    if (core.selectedTargetId != targetId) return false;
    _selectedRouteId = routeId;
    failure = null;
    notifyListeners();
    return true;
  }

  void _snapshot(CoreCastRouteSnapshot value) {
    if (_disposed || !active) return;
    final previous = _native;
    if (previous != null && value.revision <= previous.revision) {
      _fail('stale');
      return;
    }
    _native = value;
    _reconcile();
  }

  void _coreChanged() {
    if (_disposed || !active) return;
    _reconcile();
  }

  void _reconcile() {
    final inventory = core.inventory;
    final native = _native;
    if (!core.isAuthorized || inventory == null || native == null) {
      routes = const [];
      if (!core.isAuthorized) failure = 'unauthorized';
      notifyListeners();
      return;
    }
    routes = List.unmodifiable(
      native.routes.map((route) {
        final matches = inventory.targets.where(
          (target) =>
              target.transport == CoreMusicTransport.chromecast &&
              target.id == route.id &&
              target.available &&
              target.enabled,
        );
        return CoreCastRouteBinding(
          route: route,
          coreTargetId: matches.length == 1 ? matches.single.id : null,
        );
      }),
    );
    final selected = _selectedRouteId;
    if (selected != null && !routes.any((item) => item.route.id == selected)) {
      failure = 'route_lost';
      _selectedRouteId = null;
    }
    notifyListeners();
  }

  void _fail(String code) {
    if (_disposed) return;
    _native = null;
    routes = const [];
    active = false;
    failure = code;
    notifyListeners();
    unawaited(platform.stop().catchError((_) {}));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    core.removeListener(_coreChanged);
    await _subscription.cancel();
    try {
      await platform.stop();
    } catch (_) {
      // Native discovery may already be gone with the Activity lifecycle.
    }
    super.dispose();
  }
}
