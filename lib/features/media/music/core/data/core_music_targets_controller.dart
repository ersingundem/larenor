import 'package:flutter/foundation.dart';

import '../../../../server/domain/server_models.dart';
import '../domain/core_music_playback_models.dart';
import '../domain/core_music_target_models.dart';
import 'core_music_playback_api.dart';
import 'core_music_targets_api.dart';

class CoreMusicTargetsController extends ChangeNotifier {
  CoreMusicTargetsController({
    required this.api,
    this.playbackApi,
    required this.lifecycle,
    required this.authorized,
  }) {
    lifecycle.addListener(_lifecycleChanged);
  }

  final CoreMusicTargetsApi api;
  final CoreMusicPlaybackApi? playbackApi;
  final Listenable lifecycle;
  final bool Function() authorized;
  int _epoch = 0;
  bool _disposed = false;
  bool _visible = false;

  bool busy = false;
  bool loaded = false;
  String? failure;
  CoreMusicTargetInventory? inventory;
  String? selectedTargetId;
  CoreMusicPlaybackReceipt? lastReceipt;
  bool outcomeUnknown = false;

  CoreMusicTarget? get selectedTarget {
    final id = selectedTargetId;
    if (id == null) return null;
    for (final target in inventory?.targets ?? const <CoreMusicTarget>[]) {
      if (target.id == id) return target;
    }
    return null;
  }

  CoreMusicMediaSessionState get mediaSessionState =>
      CoreMusicMediaSessionState.fromTarget(selectedTarget);

  bool get isAuthorized => !_disposed && authorized();

  void setVisible(bool value) {
    if (_disposed || value == _visible) return;
    _visible = value;
    if (!value) {
      _retire(clear: true);
    } else if (isAuthorized && !loaded) {
      refresh();
    }
  }

  void _lifecycleChanged() {
    if (!_visible || !isAuthorized) _retire(clear: true);
  }

  void _retire({required bool clear}) {
    _epoch++;
    busy = false;
    failure = null;
    if (clear) {
      loaded = false;
      inventory = null;
      selectedTargetId = null;
      lastReceipt = null;
      outcomeUnknown = false;
    }
    _emit();
  }

  bool _current(int epoch) =>
      !_disposed && _visible && isAuthorized && epoch == _epoch;

  Future<void> refresh() async {
    if (_disposed || !_visible || busy || !isAuthorized) return;
    final epoch = ++_epoch;
    busy = true;
    failure = null;
    _emit();
    try {
      final value = await api.read(isCurrent: () => _current(epoch));
      if (!_current(epoch)) return;
      inventory = value;
      loaded = true;
      if (selectedTargetId != null &&
          !value.targets.any(
            (target) =>
                target.id == selectedTargetId &&
                target.available &&
                target.enabled,
          )) {
        selectedTargetId = null;
      }
    } catch (error) {
      if (!_current(epoch)) return;
      loaded = true;
      inventory = null;
      selectedTargetId = null;
      failure = error is LarenorServerException
          ? error.code
          : error is CoreMusicTargetsException
          ? error.code
          : 'connection_failed';
    } finally {
      if (_current(epoch)) {
        busy = false;
        _emit();
      }
    }
  }

  void select(String targetId) {
    if (!_visible || !isAuthorized) return;
    final target = inventory?.targets.cast<CoreMusicTarget?>().firstWhere(
      (item) => item?.id == targetId,
      orElse: () => null,
    );
    if (target == null || !target.available || !target.enabled) return;
    selectedTargetId = targetId;
    lastReceipt = null;
    outcomeUnknown = false;
    _emit();
  }

  bool canExecute(CoreMusicPlaybackOperation operation) {
    final target = selectedTarget;
    return playbackApi != null &&
        !busy &&
        _visible &&
        isAuthorized &&
        target != null &&
        target.available &&
        target.enabled &&
        target.capabilities.contains(operation.capability);
  }

  Future<void> execute(
    CoreMusicPlaybackOperation operation, {
    int? volumeLevel,
  }) async {
    final commandApi = playbackApi;
    final currentInventory = inventory;
    final target = selectedTarget;
    if (commandApi == null ||
        currentInventory == null ||
        target == null ||
        !canExecute(operation) ||
        (operation == CoreMusicPlaybackOperation.volume) !=
            (volumeLevel != null) ||
        (volumeLevel != null && (volumeLevel < 0 || volumeLevel > 100))) {
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    failure = null;
    lastReceipt = null;
    outcomeUnknown = false;
    _emit();
    try {
      final receipt = await commandApi.execute(
        inventory: currentInventory,
        target: target,
        operation: operation,
        volumeLevel: volumeLevel,
        isCurrent: () => _current(epoch),
      );
      if (!_current(epoch)) return;
      if (receipt.state != CoreMusicReceiptState.succeeded) {
        outcomeUnknown = true;
        failure = 'effect_unknown';
        inventory = null;
        selectedTargetId = null;
        loaded = true;
        return;
      }
      final readback = await api.read(isCurrent: () => _current(epoch));
      if (!_current(epoch)) return;
      final refreshed = readback.targets.any(
        (item) => item.id == target.id && item.available && item.enabled,
      );
      if (readback.playerRevision != receipt.playerRevision || !refreshed) {
        throw const LarenorServerException('stale');
      }
      inventory = readback;
      selectedTargetId = target.id;
      lastReceipt = receipt;
      loaded = true;
    } catch (error) {
      if (!_current(epoch)) return;
      failure = error is LarenorServerException
          ? error.code
          : error is CoreMusicTargetsException
          ? error.code
          : 'connection_failed';
      if ({
        'timeout',
        'connection_failed',
        'server_error',
        'music_playback_worker_unavailable',
      }.contains(failure)) {
        outcomeUnknown = true;
      }
      inventory = null;
      selectedTargetId = null;
      loaded = true;
    } finally {
      if (_current(epoch)) {
        busy = false;
        _emit();
      }
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    lifecycle.removeListener(_lifecycleChanged);
    super.dispose();
  }
}
