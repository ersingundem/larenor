import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/dual_display_session.dart';
import '../presentation/dual_display_task_screen.dart';
import 'dual_display_platform_port.dart';

final class DualDisplayTaskController extends ChangeNotifier
    implements DualDisplayTaskViewModel {
  DualDisplayTaskController(
    this._platform,
    this._authorityResolver,
    this._isCurrent,
  );

  final DualDisplayPlatformPort _platform;
  final DisplayRouteAuthority Function() _authorityResolver;
  final bool Function() _isCurrent;
  DualDisplayCoordinator? _coordinator;
  DisplayTopology? _topology;
  bool _busy = false, _disposed = false;
  String? _failure;
  int _operation = 0;

  @override
  bool get busy => _busy;
  @override
  String? get failure => _failure;
  @override
  DisplayTopology? get topology => _topology;
  @override
  DualDisplayState? get state => _coordinator?.state;

  bool _current(int operation) =>
      !_disposed && operation == _operation && _isCurrent();

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> refresh() async {
    if (_disposed || _busy || !_isCurrent()) return;
    final operation = ++_operation;
    _busy = true;
    _failure = null;
    _emit();
    try {
      final next = await _platform.snapshot();
      if (!_current(operation)) return;
      _topology = next;
      final coordinator = _coordinator;
      if (coordinator == null) {
        _coordinator = DualDisplayCoordinator(
          authorityResolver: _authorityResolver,
          topologyResolver: () => _topology!,
          port: _platform,
        );
      } else {
        await coordinator.updateTopology(next);
        if (!_current(operation)) return;
      }
    } catch (_) {
      if (_current(operation)) {
        _failure = 'display_unavailable';
        await _retireCoordinator();
        _topology = null;
      }
    } finally {
      if (_current(operation)) {
        _busy = false;
        _emit();
      }
    }
  }

  @override
  Future<void> activate(DisplaySurface display, String routeId) async {
    if (_disposed || _busy || !_isCurrent()) return;
    final topology = _topology, coordinator = _coordinator;
    final currentDisplay = topology?.externalById(display.displayId);
    if (topology == null ||
        coordinator == null ||
        currentDisplay != display ||
        !const {'dashboard.overview', 'media.now-playing'}.contains(routeId)) {
      _failure = 'stale_display';
      _emit();
      return;
    }
    final operation = ++_operation;
    final authority = _authorityResolver();
    _busy = true;
    _failure = null;
    _emit();
    try {
      await coordinator.activate(
        authority: authority,
        topology: topology,
        secondaryDisplayId: display.displayId,
        selection: DisplayRouteSelection(
          primaryRouteId: 'dashboard.home',
          secondaryRouteId: routeId,
          secondarySensitivity: RouteSensitivity.public,
          focusOwner: DisplayOwner.primary,
          playerOwner: routeId == 'media.now-playing'
              ? DisplayOwner.secondary
              : DisplayOwner.none,
        ),
      );
      if (!_current(operation) || _authorityResolver() != authority) {
        await coordinator.updateLifecycle(DisplayLifecycle.inactive);
        return;
      }
      if (coordinator.state.status != DualDisplayStatus.active) {
        _failure = 'presentation_failed';
      }
    } catch (_) {
      if (_current(operation)) _failure = 'request_rejected';
    } finally {
      if (_current(operation)) {
        _busy = false;
        _emit();
      }
    }
  }

  @override
  Future<void> disconnect() async {
    if (_disposed || _busy || !_isCurrent() || _coordinator == null) return;
    final operation = ++_operation;
    _busy = true;
    _failure = null;
    _emit();
    try {
      await _coordinator!.updateLifecycle(DisplayLifecycle.inactive);
      if (!_current(operation)) return;
      await _coordinator!.updateLifecycle(DisplayLifecycle.resumed);
    } catch (_) {
      if (_current(operation)) _failure = 'disconnect_failed';
    } finally {
      if (_current(operation)) {
        _busy = false;
        _emit();
      }
    }
  }

  Future<void> _retireCoordinator() async {
    final coordinator = _coordinator;
    _coordinator = null;
    if (coordinator != null) {
      try {
        await coordinator.updateLifecycle(DisplayLifecycle.inactive);
      } catch (_) {
        // Local ownership is still dropped; a late native receipt is ignored.
      }
    }
  }

  void retire() {
    if (_disposed) return;
    _operation++;
    _busy = false;
    _failure = null;
    final retirement = _retireCoordinator();
    _topology = null;
    unawaited(retirement);
    _emit();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _operation++;
    unawaited(_retireCoordinator());
    super.dispose();
  }
}
