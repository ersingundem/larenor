import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../shared/network/server_bound_client.dart';
import '../domain/client_update_models.dart';
import 'client_update_api.dart';

/// Create a new source on every authenticated server-session change. The
/// callback checks that account/session identity, not route visibility.
class ClientUpdateSource {
  ClientUpdateSource({
    required String baseUrl,
    required this.accessToken,
    required this.isCurrent,
  }) : baseUrl = parseServerUrl(baseUrl).toString();
  final String baseUrl, accessToken;
  final bool Function() isCurrent;
  @override
  String toString() => 'Authenticated update source';
}

enum ClientUpdatePhase {
  idle,
  downloading,
  verifying,
  ready,
  installing,
  systemPromptOpened,
}

class ClientUpdateController extends ChangeNotifier {
  ClientUpdateController(this._api, this.source) : _sessionId = _uuid() {
    _subscription = _api.progress.listen(
      _progress,
      onError: (Object _) {
        // Invalid progress is not proof that the APK transfer/verification failed.
        // Its separate bounded method result remains authoritative.
      },
    );
  }
  final ClientUpdateApi _api;
  final ClientUpdateSource source;
  final String _sessionId;
  late final StreamSubscription<ClientUpdateProgress> _subscription;
  bool _disposed = false, _visible = false, _busy = false;
  int _epoch = 0;
  String? _downloadId;
  ClientUpdatePhase _phase = ClientUpdatePhase.idle;
  ClientUpdateFailure? _failure;
  ClientRelease? _release;
  StagedClientUpdate? _staged;
  ClientUpdateProgress? _transfer;
  InstalledClientSnapshot? _snapshot;
  ClientUpdatePhase get phase => _phase;
  ClientUpdateFailure? get failure => _failure;
  ClientRelease? get release => _release;
  StagedClientUpdate? get staged => _staged;
  ClientUpdateProgress? get transfer => _transfer;
  InstalledClientSnapshot? get snapshot => _snapshot;
  bool get busy => _busy;
  bool get visible => _visible;
  bool get _current => !_disposed && _visible && source.isCurrent();
  bool _same(int epoch) => _current && _epoch == epoch;
  void _check([int? epoch]) {
    if (!_current || (epoch != null && epoch != _epoch)) {
      throw const ClientUpdateException(ClientUpdateFailure.expired);
    }
  }

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    if (!value) {
      _epoch++;
      _busy = false;
      _downloadId = null;
      _transfer = null;
      if (_phase != ClientUpdatePhase.systemPromptOpened) {
        _phase = _staged == null
            ? ClientUpdatePhase.idle
            : ClientUpdatePhase.ready;
      }
      unawaited(_ignore(_api.cancel(_sessionId)));
    }
    notifyListeners();
  }

  void _progress(ClientUpdateProgress progress) {
    if (!_current ||
        !_busy ||
        progress.sessionId != _sessionId ||
        progress.downloadId != _downloadId ||
        progress.totalBytes != _release?.sizeBytes ||
        progress.receivedBytes < (_transfer?.receivedBytes ?? 0)) {
      return;
    }
    _transfer = progress;
    _phase = progress.phase == ClientUpdateTransferPhase.verifying
        ? ClientUpdatePhase.verifying
        : ClientUpdatePhase.downloading;
    notifyListeners();
  }

  Future<void> refreshSnapshot() async {
    _check();
    final epoch = _epoch;
    final snapshot = await _api.snapshot();
    _check(epoch);
    _snapshot = snapshot;
    notifyListeners();
  }

  Future<void> download(ClientRelease release) async {
    _check();
    if (_busy) throw const ClientUpdateException(ClientUpdateFailure.busy);
    final epoch = ++_epoch;
    final id = _uuid();
    _busy = true;
    _failure = null;
    _release = release;
    _staged = null;
    _transfer = null;
    _phase = ClientUpdatePhase.downloading;
    _downloadId = id;
    notifyListeners();
    try {
      await _api.activateSession(_sessionId);
      _check(epoch);
      final installed = await _api.snapshot();
      _check(epoch);
      _snapshot = installed;
      if (!installed.supported) {
        throw const ClientUpdateException(ClientUpdateFailure.unsupported);
      }
      if (!installed.accepts(release)) {
        throw const ClientUpdateException(ClientUpdateFailure.incompatible);
      }
      final staged = await _api.download(
        sessionId: _sessionId,
        downloadId: id,
        baseUrl: source.baseUrl,
        accessToken: source.accessToken,
        release: release,
        interactionEpoch: installed.interactionEpoch,
      );
      _check(epoch);
      if (staged.id != id ||
          staged.versionCode != release.versionCode ||
          staged.sizeBytes != release.sizeBytes) {
        await _api.invalidate(_sessionId);
        _check(epoch);
        throw const ClientUpdateException(ClientUpdateFailure.verification);
      }
      _staged = staged;
      _phase = ClientUpdatePhase.ready;
    } catch (e) {
      if (_same(epoch)) {
        _failure = _safe(e);
        _phase = ClientUpdatePhase.idle;
        unawaited(_ignore(_api.cancel(_sessionId)));
      }
      if (e is ClientUpdateException) rethrow;
      throw const ClientUpdateException(ClientUpdateFailure.unavailable);
    } finally {
      if (_same(epoch)) {
        _busy = false;
        _downloadId = null;
        notifyListeners();
      }
    }
  }

  Future<void> cancel() async {
    if (_disposed) return;
    _epoch++;
    _busy = false;
    _downloadId = null;
    _transfer = null;
    _phase = _staged == null ? ClientUpdatePhase.idle : ClientUpdatePhase.ready;
    notifyListeners();
    await _ignore(_api.cancel(_sessionId));
  }

  Future<ClientInstallOutcome> install() async {
    _check();
    if (_busy) throw const ClientUpdateException(ClientUpdateFailure.busy);
    final staged = _staged;
    if (staged == null) {
      throw const ClientUpdateException(ClientUpdateFailure.expired);
    }
    final epoch = ++_epoch;
    _busy = true;
    _failure = null;
    notifyListeners();
    var dispatched = false;
    try {
      final installed = await _api.snapshot();
      _check(epoch);
      _snapshot = installed;
      if (!installed.canRequestPackageInstalls) {
        throw const ClientUpdateException(
          ClientUpdateFailure.installPermission,
        );
      }
      if (_release == null || !installed.accepts(_release!)) {
        throw const ClientUpdateException(ClientUpdateFailure.incompatible);
      }
      // Retire before dispatch. If Android pauses us while opening its dialog,
      // an old callback cannot re-enable the consumed install handle on resume.
      _staged = null;
      _phase = ClientUpdatePhase.installing;
      dispatched = true;
      notifyListeners();
      final outcome = await _api.install(
        _sessionId,
        staged,
        interactionEpoch: installed.interactionEpoch,
      );
      if (!_disposed && source.isCurrent()) {
        _phase = ClientUpdatePhase.systemPromptOpened;
      }
      return outcome;
    } catch (e) {
      if (_same(epoch)) {
        _failure = _safe(e);
        _phase = _staged == null
            ? ClientUpdatePhase.idle
            : ClientUpdatePhase.ready;
      }
      if (e is ClientUpdateException) rethrow;
      throw const ClientUpdateException(ClientUpdateFailure.unavailable);
    } finally {
      if (_same(epoch) || (dispatched && !_disposed && source.isCurrent())) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> openInstallPermission() async {
    _check();
    if (_busy) throw const ClientUpdateException(ClientUpdateFailure.busy);
    final epoch = ++_epoch;
    _busy = true;
    notifyListeners();
    try {
      await _api.activateSession(_sessionId);
      _check(epoch);
      final installed = await _api.snapshot();
      _check(epoch);
      // A separate user action; returning from Android never starts an install.
      await _api.openInstallPermission(
        _sessionId,
        interactionEpoch: installed.interactionEpoch,
      );
    } finally {
      if (_same(epoch)) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  void invalidate() {
    if (_disposed) return;
    _epoch++;
    _visible = false;
    _busy = false;
    _staged = null;
    _release = null;
    _transfer = null;
    _snapshot = null;
    _phase = ClientUpdatePhase.idle;
    unawaited(_ignore(_api.invalidate(_sessionId)));
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _staged = null;
    _release = null;
    unawaited(_subscription.cancel());
    unawaited(_ignore(_api.invalidate(_sessionId)));
    super.dispose();
  }
}

ClientUpdateFailure _safe(Object error) => error is ClientUpdateException
    ? error.failure
    : ClientUpdateFailure.unavailable;
Future<void> _ignore(Future<void> task) async {
  try {
    await task;
  } catch (_) {}
}

String _uuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
