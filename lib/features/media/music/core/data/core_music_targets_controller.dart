import 'package:flutter/foundation.dart';

import '../../../../server/domain/server_models.dart';
import '../domain/core_music_target_models.dart';
import 'core_music_targets_api.dart';

class CoreMusicTargetsController extends ChangeNotifier {
  CoreMusicTargetsController({
    required this.api,
    required this.lifecycle,
    required this.authorized,
  }) {
    lifecycle.addListener(_lifecycleChanged);
  }

  final CoreMusicTargetsApi api;
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
          !value.targets.any((target) => target.id == selectedTargetId)) {
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
    _emit();
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
