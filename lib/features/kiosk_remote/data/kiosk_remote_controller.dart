import 'package:flutter/foundation.dart';

import '../domain/kiosk_remote_models.dart';
import 'kiosk_remote_api.dart';

enum KioskRemoteViewState { idle, loading, ready, failed, stale }

final class KioskRemoteController extends ChangeNotifier {
  KioskRemoteController({required this.api, required this.isCurrent});
  final KioskRemoteApi api;
  final bool Function() isCurrent;
  KioskRemoteViewState state = KioskRemoteViewState.idle;
  KioskRemoteSnapshot? snapshot;
  String? oneTimeToken;
  bool busy = false;
  bool _interactive = true, _disposed = false;
  int _epoch = 0;

  bool _current(int epoch) {
    try {
      return !_disposed && _interactive && epoch == _epoch && isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _stale() {
    snapshot = null;
    oneTimeToken = null;
    busy = false;
    state = KioskRemoteViewState.stale;
    if (!_disposed) notifyListeners();
  }

  void setInteractive(bool value) {
    if (_disposed || value == _interactive) return;
    _interactive = value;
    if (!value) {
      _epoch++;
      api.retire();
      _stale();
    }
  }

  Future<void> load() => _run(() async {
    snapshot = await api.load();
    oneTimeToken = null;
  });

  Future<void> create(KioskRemoteDevice device, Set<String> scopes) =>
      _run(() async {
        final created = await api.create(device, scopes);
        final current =
            snapshot ?? const KioskRemoteSnapshot(devices: [], pairings: []);
        snapshot = KioskRemoteSnapshot(
          devices: current.devices,
          pairings: [...current.pairings, created.pairing],
        );
        oneTimeToken = created.token;
      });

  Future<void> revoke(KioskRemotePairing pairing) => _run(() async {
    await api.revoke(pairing);
    final current = snapshot;
    if (current != null) {
      snapshot = KioskRemoteSnapshot(
        devices: current.devices,
        pairings: current.pairings
            .where((item) => item.id != pairing.id)
            .toList(),
      );
    }
    oneTimeToken = null;
  });

  Future<void> _run(Future<void> Function() operation) async {
    if (busy) return;
    final epoch = ++_epoch;
    if (!_current(epoch)) return _stale();
    busy = true;
    oneTimeToken = null;
    state = snapshot == null
        ? KioskRemoteViewState.loading
        : KioskRemoteViewState.ready;
    notifyListeners();
    try {
      await operation();
      if (!_current(epoch)) return _stale();
      state = KioskRemoteViewState.ready;
    } catch (_) {
      if (!_current(epoch)) return _stale();
      state = KioskRemoteViewState.failed;
    }
    busy = false;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    api.retire();
    super.dispose();
  }
}
