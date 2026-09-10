import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/remote_profiles.dart';
import 'ssh_security_store.dart';
import 'ssh_tunnel_engine.dart';
import 'ssh_tunnel_models.dart';

enum SshTunnelPhase {
  idle,
  loading,
  ready,
  connecting,
  hostKey,
  active,
  closed,
  failed,
}

class SshTunnelController extends ChangeNotifier {
  SshTunnelController({
    required this.profile,
    required this.store,
    required this.engineFactory,
    required this.isCurrent,
  });
  final RemoteProfile profile;
  final SshSecurityStore store;
  final SshTunnelEngine Function() engineFactory;
  final bool Function() isCurrent;
  SshTunnelPhase phase = SshTunnelPhase.idle;
  SshTunnelProfile? tunnel;
  SshHostPin? pendingPin;
  String? error;
  String? notice;
  String? localEndpoint;
  SshTunnelEngine? _engine;
  SshTunnelHandle? _handle;
  Completer<bool>? _decision;
  int _generation = 0;
  bool _retired = false, _disposed = false;

  bool _current(int generation) {
    try {
      return !_retired &&
          !_disposed &&
          generation == _generation &&
          isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _check(int generation) {
    if (!_current(generation)) throw const SshFailure('retired');
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _close() {
    if (_decision?.isCompleted == false) _decision!.complete(false);
    _decision = null;
    pendingPin = null;
    _handle?.close();
    _handle = null;
    _engine?.close();
    _engine = null;
    localEndpoint = null;
  }

  void _end({String? code}) {
    _generation++;
    _close();
    error = code;
    notice = null;
    phase = code == null ? SshTunnelPhase.closed : SshTunnelPhase.failed;
    _publish();
  }

  Future<void> load() async {
    if (_disposed || _retired || phase == SshTunnelPhase.loading) return;
    _generation++;
    final generation = _generation;
    _close();
    phase = SshTunnelPhase.loading;
    error = null;
    _publish();
    try {
      tunnel = await store.readTunnel(
        profile,
        isCurrent: () => _current(generation),
      );
      _check(generation);
      phase = SshTunnelPhase.ready;
      _publish();
    } catch (e) {
      if (generation == _generation) {
        _end(code: e is SshFailure ? e.code : 'storage_failed');
      }
    }
  }

  Future<void> save(SshTunnelProfile value) async {
    if (_disposed ||
        _retired ||
        (phase != SshTunnelPhase.ready && phase != SshTunnelPhase.idle)) {
      return;
    }
    final generation = _generation;
    try {
      await store.saveTunnel(
        profile,
        value,
        isCurrent: () => _current(generation),
      );
      _check(generation);
      tunnel = value;
      notice = 'saved';
      phase = SshTunnelPhase.ready;
      _publish();
    } catch (e) {
      if (generation == _generation) {
        _end(code: e is SshFailure ? e.code : 'storage_failed');
      }
    }
  }

  Future<void> start() async {
    if (phase != SshTunnelPhase.ready || tunnel == null) return;
    final generation = ++_generation;
    _close();
    phase = SshTunnelPhase.connecting;
    error = null;
    notice = null;
    _publish();
    try {
      await store.checkProfile(profile, isCurrent: () => _current(generation));
      final credential = await store.readCredential(
        profile,
        isCurrent: () => _current(generation),
      );
      _check(generation);
      if (credential == null) throw const SshFailure('credential_missing');
      final engine = engineFactory();
      _engine = engine;
      final handle = await engine.start(
        profile,
        credential,
        tunnel!,
        isCurrent: () => _current(generation),
        verifyHost: (pin) async {
          final old = await store.readPin(
            profile,
            isCurrent: () => _current(generation),
          );
          _check(generation);
          if (old != null) {
            if (old.type != pin.type || old.fingerprint != pin.fingerprint) {
              throw const SshFailure('host_changed');
            }
            return true;
          }
          final decision = _decision = Completer<bool>();
          pendingPin = pin;
          phase = SshTunnelPhase.hostKey;
          _publish();
          final accepted = await decision.future;
          _check(generation);
          return accepted;
        },
      );
      _check(generation);
      _handle = handle;
      localEndpoint = '${handle.localAddress}:${handle.localPort}';
      phase = SshTunnelPhase.active;
      _publish();
      unawaited(
        handle.done.then(
          (_) {
            if (generation == _generation && !_disposed) {
              _end(code: 'connection_lost');
            }
          },
          onError: (_) {
            if (generation == _generation && !_disposed) {
              _end(code: 'connection_lost');
            }
          },
        ),
      );
    } catch (e) {
      if (generation == _generation) {
        _end(code: e is SshFailure ? e.code : 'connection_failed');
      }
    }
  }

  Future<void> trustHost() async {
    final generation = _generation, decision = _decision, pin = pendingPin;
    if (phase != SshTunnelPhase.hostKey ||
        decision == null ||
        pin == null ||
        decision.isCompleted) {
      return;
    }
    try {
      await store.trust(profile, pin, isCurrent: () => _current(generation));
      _check(generation);
      pendingPin = null;
      phase = SshTunnelPhase.connecting;
      decision.complete(true);
      _publish();
    } catch (e) {
      if (generation == _generation) {
        _end(code: e is SshFailure ? e.code : 'storage_failed');
      }
    }
  }

  void cancel() {
    if (_disposed) return;
    _generation++;
    _close();
    error = null;
    notice = null;
    phase = tunnel == null ? SshTunnelPhase.idle : SshTunnelPhase.ready;
    _publish();
  }

  void retire() {
    if (_retired || _disposed) return;
    _retired = true;
    _end();
  }

  @override
  void dispose() {
    _disposed = true;
    _retired = true;
    _generation++;
    _close();
    super.dispose();
  }
}
