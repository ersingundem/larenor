import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/dual_display_session.dart';
import '../presentation/dual_display_task_screen.dart';
import 'dual_display_authority_api.dart';
import 'dual_display_platform_port.dart';

final class DualDisplayTaskController extends ChangeNotifier
    implements DualDisplayTaskViewModel {
  DualDisplayTaskController(
    this._platform,
    DualDisplayAuthorityReading Function() authorityResolver,
    this._isCurrent,
  ) : _legacyAuthorityResolver = authorityResolver,
      _authorityReader = null {
    _listen();
  }

  DualDisplayTaskController.authorized(
    this._platform,
    DualDisplayAuthorityReader authorityReader,
    this._isCurrent,
  ) : _legacyAuthorityResolver = null,
      _authorityReader = authorityReader {
    _listen();
  }

  void _listen() {
    final platform = _platform;
    if (platform is Listenable) {
      (platform as Listenable).addListener(_platformChanged);
    }
  }

  final DualDisplayPlatformPort _platform;
  final DualDisplayAuthorityReading Function()? _legacyAuthorityResolver;
  final DualDisplayAuthorityReader? _authorityReader;
  final bool Function() _isCurrent;
  DisplayRouteAuthority? _verifiedAuthority;
  DualDisplayCoordinator? _coordinator;
  DisplayTopology? _topology;
  bool _busy = false, _disposed = false;
  String? _failure;
  int _operation = 0;
  bool _topologyEventPending = false;
  Timer? _publicRefresh;

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

  DisplayRouteAuthority _authority() {
    final verified = _verifiedAuthority;
    if (verified != null) return verified;
    final legacy = _legacyAuthorityResolver;
    if (legacy != null) return legacy().authority;
    throw const DualDisplayException('authority_unavailable');
  }

  Future<DualDisplayAuthorityReading> _readAuthority(int operation) async {
    final reader = _authorityReader;
    final authority = reader == null
        ? _legacyAuthorityResolver!()
        : await reader(() => _current(operation));
    if (!_current(operation)) {
      throw const DualDisplayException('stale_authority');
    }
    return authority;
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _platformChanged() {
    if (_disposed) return;
    _topologyEventPending = true;
    _drainTopologyEvent();
  }

  void _drainTopologyEvent() {
    if (_disposed || _busy || !_topologyEventPending) return;
    _topologyEventPending = false;
    scheduleMicrotask(() async {
      if (_disposed || _busy || !_isCurrent()) return;
      await refresh();
      if (_topologyEventPending) _drainTopologyEvent();
    });
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
          authorityResolver: _authority,
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
        _drainTopologyEvent();
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
        routeId != 'core.status') {
      _failure = 'stale_display';
      _emit();
      return;
    }
    final operation = ++_operation;
    _busy = true;
    _failure = null;
    _emit();
    try {
      final reading = await _readAuthority(operation);
      final authority = reading.authority;
      _verifiedAuthority = authority;
      await coordinator.activate(
        authority: authority,
        topology: topology,
        secondaryDisplayId: display.displayId,
        selection: DisplayRouteSelection(
          primaryRouteId: 'settings.external-display',
          secondaryRouteId: routeId,
          secondarySensitivity: RouteSensitivity.public,
          focusOwner: DisplayOwner.primary,
          playerOwner: DisplayOwner.none,
        ),
        publicSnapshot: reading.publicSnapshot,
      );
      if (!_current(operation)) {
        await coordinator.updateLifecycle(DisplayLifecycle.inactive);
        return;
      }
      final after = await _readAuthority(operation);
      if (after.authority != authority) {
        _verifiedAuthority = after.authority;
        await coordinator.updateAuthority(after.authority);
        _failure = 'stale_authority';
        return;
      }
      if (coordinator.state.status != DualDisplayStatus.active) {
        _failure = 'presentation_failed';
      } else {
        if (after.publicSnapshot.snapshotRevision !=
            reading.publicSnapshot.snapshotRevision) {
          final published = await coordinator.publishPublicSnapshot(
            after.publicSnapshot,
          );
          if (!published) {
            _failure = 'presentation_failed';
            return;
          }
        }
        _startPublicRefresh();
      }
    } catch (_) {
      if (_current(operation)) {
        _failure = 'request_rejected';
        await _retireCoordinator();
      }
    } finally {
      if (_current(operation)) {
        _busy = false;
        _emit();
        _drainTopologyEvent();
      }
    }
  }

  void _startPublicRefresh() {
    _publicRefresh?.cancel();
    _publicRefresh = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refreshPublicSnapshot()),
    );
  }

  Future<void> _refreshPublicSnapshot() async {
    final coordinator = _coordinator;
    final expected = _verifiedAuthority;
    if (_disposed ||
        _busy ||
        !_isCurrent() ||
        coordinator == null ||
        expected == null ||
        coordinator.state.status != DualDisplayStatus.active) {
      return;
    }
    final operation = ++_operation;
    try {
      final reading = await _readAuthority(operation);
      if (!_current(operation)) return;
      if (reading.authority != expected) {
        _verifiedAuthority = reading.authority;
        await coordinator.updateAuthority(reading.authority);
        throw const DualDisplayException('stale_authority');
      }
      if (!await coordinator.publishPublicSnapshot(reading.publicSnapshot)) {
        throw const DualDisplayException('presentation_failed');
      }
    } catch (_) {
      if (_current(operation)) {
        _failure = 'public_snapshot_unavailable';
        _publicRefresh?.cancel();
        _publicRefresh = null;
        await _retireCoordinator();
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
        _drainTopologyEvent();
      }
    }
  }

  Future<void> _retireCoordinator() async {
    _publicRefresh?.cancel();
    _publicRefresh = null;
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
    _verifiedAuthority = null;
    _topology = null;
    unawaited(retirement);
    _emit();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final platform = _platform;
    if (platform is Listenable) {
      (platform as Listenable).removeListener(_platformChanged);
    }
    _operation++;
    _publicRefresh?.cancel();
    _publicRefresh = null;
    unawaited(_retireCoordinator());
    super.dispose();
  }
}
