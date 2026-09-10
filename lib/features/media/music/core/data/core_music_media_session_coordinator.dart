import 'dart:async';

import '../domain/core_music_playback_models.dart';
import 'core_music_media_session_bridge.dart';
import 'core_music_targets_controller.dart';

/// Keeps native controls bound to one authenticated target/revision. A PIN
/// grant is short-lived and is never sent to Android; Android receives only a
/// boolean capability and a process-local opaque session identifier.
class CoreMusicMediaSessionCoordinator {
  CoreMusicMediaSessionCoordinator({
    required this.controller,
    required this.platform,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    controller.addListener(_changed);
    _actions = platform.actions.listen(
      _nativeAction,
      onError: (_) => _failClosed(),
    );
    _changed();
  }

  static const authorizationLifetime = Duration(minutes: 2);
  final CoreMusicTargetsController controller;
  final CoreMusicMediaSessionPlatform platform;
  final DateTime Function() _clock;
  late final StreamSubscription<CoreMusicMediaSessionAction> _actions;
  Timer? _leaseTimer;
  String? _leaseTarget;
  int? _leaseRevision;
  DateTime? _leaseDeadline;
  int _epoch = 0;
  bool _disposed = false;
  bool _nativeBusy = false;

  bool get controlsAuthorized {
    final inventory = controller.inventory;
    return !_disposed &&
        _leaseTarget != null &&
        controller.selectedTargetId == _leaseTarget &&
        inventory?.playerRevision == _leaseRevision &&
        _leaseDeadline != null &&
        _clock().isBefore(_leaseDeadline!) &&
        controller.selectedTarget?.available == true &&
        controller.selectedTarget?.enabled == true &&
        !controller.outcomeUnknown;
  }

  void authorizeCurrent() {
    final target = controller.selectedTarget;
    final inventory = controller.inventory;
    if (_disposed || target == null || inventory == null) return;
    _leaseTarget = target.id;
    _leaseRevision = inventory.playerRevision;
    _leaseDeadline = _clock().add(authorizationLifetime);
    _leaseTimer?.cancel();
    _leaseTimer = Timer(authorizationLifetime, _revoke);
    _changed();
  }

  void revokeAuthorization() => _revoke();

  void _revoke() {
    _leaseTarget = null;
    _leaseRevision = null;
    _leaseDeadline = null;
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    final inventory = controller.inventory;
    final target = controller.selectedTarget;
    final receipt = controller.lastReceipt;
    if (_leaseTarget != null &&
        receipt != null &&
        receipt.targetId == _leaseTarget &&
        target?.id == _leaseTarget &&
        receipt.playerRevision == inventory?.playerRevision &&
        _clock().isBefore(_leaseDeadline!)) {
      _leaseRevision = receipt.playerRevision;
    }
    final epoch = ++_epoch;
    if (inventory == null ||
        target == null ||
        controller.failure != null ||
        controller.outcomeUnknown) {
      _leaseTarget = null;
      _leaseRevision = null;
      _leaseDeadline = null;
      _leaseTimer?.cancel();
      _leaseTimer = null;
      unawaited(_clear(epoch));
      return;
    }
    // A native action is already sealed by the native single-flight gate.
    // Keep the previous snapshot until Core returns a newer authenticated
    // revision; publishing the old revision would look like a replay.
    if (controller.busy) return;
    unawaited(_publish(epoch, inventory.playerRevision));
  }

  Future<void> _publish(int epoch, int revision) async {
    final target = controller.selectedTarget;
    if (target == null) return;
    try {
      await platform.publish(
        state: controller.mediaSessionState,
        playerRevision: revision,
        controlsAuthorized: controlsAuthorized,
        canSeek: target.capabilities.contains('seek'),
        canVolume:
            target.capabilities.contains('volume_set') &&
            target.volumeLevel != null,
        volumeLevel: target.capabilities.contains('volume_set')
            ? target.volumeLevel
            : null,
      );
      if (_disposed || epoch != _epoch) await platform.clear();
    } catch (_) {
      if (!_disposed && epoch == _epoch) _failClosed();
    }
  }

  Future<void> _clear(int epoch) async {
    try {
      await platform.clear();
    } catch (_) {
      // A missing or retired native service is already the safe state.
    }
    if (_disposed || epoch != _epoch) return;
  }

  Future<void> _nativeAction(CoreMusicMediaSessionAction event) async {
    if (_disposed || _nativeBusy || !controlsAuthorized) {
      _failClosed();
      return;
    }
    final inventory = controller.inventory;
    if (inventory == null || event.playerRevision != inventory.playerRevision) {
      _failClosed();
      return;
    }
    final operation = switch (event.action) {
      CoreMusicNativeAction.play => CoreMusicPlaybackOperation.play,
      CoreMusicNativeAction.pause => CoreMusicPlaybackOperation.pause,
      CoreMusicNativeAction.next => CoreMusicPlaybackOperation.next,
      CoreMusicNativeAction.previous => CoreMusicPlaybackOperation.previous,
      CoreMusicNativeAction.seek => CoreMusicPlaybackOperation.seek,
      CoreMusicNativeAction.volume => CoreMusicPlaybackOperation.volume,
    };
    if (!controller.canExecute(operation)) {
      _failClosed();
      return;
    }
    _nativeBusy = true;
    try {
      await controller.execute(
        operation,
        volumeLevel: event.action == CoreMusicNativeAction.volume
            ? event.value
            : null,
        seekPosition: event.action == CoreMusicNativeAction.seek
            ? event.value! ~/ 1000
            : null,
      );
      if (controller.lastReceipt == null || controller.failure != null) {
        _failClosed();
      }
    } finally {
      _nativeBusy = false;
    }
  }

  void _failClosed() {
    if (_disposed) return;
    _leaseTarget = null;
    _leaseRevision = null;
    _leaseDeadline = null;
    _leaseTimer?.cancel();
    _leaseTimer = null;
    final epoch = ++_epoch;
    unawaited(_clear(epoch));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _leaseTimer?.cancel();
    controller.removeListener(_changed);
    await _actions.cancel();
    try {
      await platform.clear();
    } catch (_) {
      // The service may already be gone after process/activity teardown.
    }
  }
}
