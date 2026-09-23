import 'package:flutter/foundation.dart';

import '../domain/kiosk_remote_models.dart';
import 'kiosk_remote_api.dart';

enum KioskRemoteViewState { idle, loading, ready, failed, stale }

final class KioskRemoteController extends ChangeNotifier {
  KioskRemoteController({
    required this.api,
    required this.isCurrent,
    this.onPairingRevoked,
    this.onPairingEnrolled,
  });
  final KioskRemoteApi api;
  final bool Function() isCurrent;
  final Future<void> Function(String pairingId)? onPairingRevoked;
  final Future<void> Function(KioskRemoteCreated created)? onPairingEnrolled;
  KioskRemoteViewState state = KioskRemoteViewState.idle;
  KioskRemoteSnapshot? snapshot;
  String? oneTimeToken;
  String? enrolledPairingId;
  KioskRemoteCreated? _pendingEnrollment;
  bool busy = false;
  bool _interactive = true, _disposed = false;
  int _epoch = 0;

  bool get canEnrollCreatedPairing =>
      _pendingEnrollment != null && onPairingEnrolled != null;

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
    enrolledPairingId = null;
    _pendingEnrollment = null;
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
    enrolledPairingId = null;
    _pendingEnrollment = null;
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
        _pendingEnrollment = created;
        enrolledPairingId = null;
        oneTimeToken = created.token;
      });

  Future<void> enrollCreatedPairing() async {
    final created = _pendingEnrollment;
    final enroll = onPairingEnrolled;
    if (created == null || enroll == null) return;
    await _run(() async {
      await enroll(created);
      enrolledPairingId = created.pairing.id;
      _pendingEnrollment = null;
      oneTimeToken = null;
    }, clearSecret: false);
  }

  Future<void> revoke(KioskRemotePairing pairing) => _run(() async {
    await api.revoke(pairing);
    await onPairingRevoked?.call(pairing.id);
    if (_pendingEnrollment?.pairing.id == pairing.id) {
      _pendingEnrollment = null;
    }
    if (enrolledPairingId == pairing.id) enrolledPairingId = null;
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

  Future<void> _run(
    Future<void> Function() operation, {
    bool clearSecret = true,
  }) async {
    if (busy) return;
    final epoch = ++_epoch;
    if (!_current(epoch)) return _stale();
    busy = true;
    if (clearSecret) {
      oneTimeToken = null;
      _pendingEnrollment = null;
      enrolledPairingId = null;
    }
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
