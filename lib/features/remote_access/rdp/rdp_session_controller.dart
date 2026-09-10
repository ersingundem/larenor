import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/remote_profiles.dart';
import 'rdp_engine.dart';
import 'rdp_models.dart';
import 'rdp_security_store.dart';

enum RdpSessionPhase {
  idle,
  checking,
  unsupported,
  certificate,
  nlaRequired,
  connecting,
  connected,
  closed,
  failed,
}

class RdpSessionController extends ChangeNotifier {
  RdpSessionController({
    required this.profile,
    required this.trust,
    required this.engineFactory,
    required this.isCurrent,
    required this.display,
    this.connectTimeout = const Duration(seconds: 45),
  });
  final RemoteProfile profile;
  final RdpTrustStore trust;
  final RdpEngine Function() engineFactory;
  final bool Function() isCurrent;
  final RdpDisplaySpec display;
  final Duration connectTimeout;

  RdpSessionPhase phase = RdpSessionPhase.idle;
  RdpCapabilities? capabilities;
  RdpCertificatePin? pendingCertificate;
  String? error;
  bool get hasSensitiveInput => _passwordDecision != null;

  RdpEngine? _engine;
  RdpChannel? _channel;
  Completer<bool>? _certificateDecision;
  Completer<String?>? _passwordDecision;
  Timer? _timer;
  int _generation = 0;
  bool _retired = false, _disposed = false;

  bool _current(int generation) {
    try {
      return !_disposed &&
          !_retired &&
          generation == _generation &&
          isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _check(int generation) {
    if (!_current(generation)) throw const RdpFailure('retired');
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _closeResources() {
    _timer?.cancel();
    _timer = null;
    if (_certificateDecision?.isCompleted == false) {
      _certificateDecision!.complete(false);
    }
    _certificateDecision = null;
    if (_passwordDecision?.isCompleted == false) {
      _passwordDecision!.complete(null);
    }
    _passwordDecision = null;
    pendingCertificate = null;
    _channel?.close();
    _channel = null;
    _engine?.close();
    _engine = null;
  }

  void _finish({String? code, bool retired = false}) {
    _generation++;
    _retired = _retired || retired;
    _closeResources();
    error = code;
    phase = retired || code == null
        ? RdpSessionPhase.closed
        : RdpSessionPhase.failed;
    _publish();
  }

  Future<void> connect() {
    if (phase != RdpSessionPhase.idle || _retired || _disposed) {
      return Future.value();
    }
    if (!_current(_generation)) {
      retire();
      return Future.value();
    }
    final generation = ++_generation;
    phase = RdpSessionPhase.checking;
    error = null;
    capabilities = null;
    _engine = engineFactory();
    _timer = Timer(connectTimeout, () {
      if (generation == _generation) _finish(code: 'timed_out');
    });
    final opening = Completer<void>();
    _publish();
    unawaited(
      _start(generation).then(
        (_) {
          if (!opening.isCompleted) opening.complete();
        },
        onError: (Object value) {
          if (generation == _generation && !_disposed) {
            if (!_current(generation)) {
              _finish(retired: true);
            } else {
              _finish(
                code: value is RdpFailure ? value.code : 'connection_failed',
              );
            }
          }
          if (!opening.isCompleted) opening.complete();
        },
      ),
    );
    return opening.future;
  }

  Future<void> _start(int generation) async {
    final engine = _engine!;
    final found = await engine.capabilities(
      isCurrent: () => _current(generation),
    );
    _check(generation);
    capabilities = found;
    if (!found.canConnect) {
      _timer?.cancel();
      _timer = null;
      engine.close();
      _engine = null;
      phase = RdpSessionPhase.unsupported;
      _publish();
      return;
    }
    await trust.checkProfile(profile, isCurrent: () => _current(generation));
    final peer = await engine.inspect(
      profile,
      isCurrent: () => _current(generation),
    );
    _check(generation);
    peer.certificate.validate();
    if (!peer.tls) throw const RdpFailure('tls_required');
    if (peer.requiresNla && !found.supportsNla) {
      throw const RdpFailure('nla_unsupported');
    }
    final pinned = await trust.readPin(
      profile,
      isCurrent: () => _current(generation),
    );
    _check(generation);
    if (pinned != null && pinned != peer.certificate) {
      throw const RdpFailure('certificate_changed');
    }
    if (pinned == null) {
      final decision = _certificateDecision = Completer<bool>();
      pendingCertificate = peer.certificate;
      phase = RdpSessionPhase.certificate;
      _publish();
      if (!await decision.future) {
        throw const RdpFailure('certificate_rejected');
      }
      _check(generation);
      _certificateDecision = null;
      pendingCertificate = null;
    }
    String? password;
    if (peer.requiresNla) {
      final decision = _passwordDecision = Completer<String?>();
      phase = RdpSessionPhase.nlaRequired;
      _publish();
      password = await decision.future;
      _passwordDecision = null;
      _check(generation);
      if (password == null) throw const RdpFailure('nla_cancelled');
    }
    phase = RdpSessionPhase.connecting;
    _publish();
    final request = RdpSessionRequest(
      profile: profile,
      display: display,
      certificateFingerprint: peer.certificate.fingerprint,
    );
    request.validate(found);
    final channel = await engine.open(
      request,
      nlaPassword: password,
      isCurrent: () => _current(generation),
    );
    password = null;
    if (!_current(generation)) {
      channel.close();
      _check(generation);
    }
    _channel = channel;
    _timer?.cancel();
    _timer = null;
    phase = RdpSessionPhase.connected;
    _publish();
    unawaited(
      channel.done.then(
        (_) {
          if (generation == _generation) _finish();
        },
        onError: (_) {
          if (generation == _generation) _finish(code: 'connection_lost');
        },
      ),
    );
  }

  Future<void> trustCertificate() async {
    final generation = _generation,
        decision = _certificateDecision,
        pin = pendingCertificate;
    if (phase != RdpSessionPhase.certificate ||
        decision == null ||
        decision.isCompleted ||
        pin == null ||
        !_current(generation)) {
      return;
    }
    try {
      await trust.trust(profile, pin, isCurrent: () => _current(generation));
      _check(generation);
      decision.complete(true);
    } catch (value) {
      if (generation == _generation) {
        _finish(code: value is RdpFailure ? value.code : 'storage_failed');
      }
    }
  }

  Future<void> authenticate(String password) async {
    final decision = _passwordDecision;
    if (phase != RdpSessionPhase.nlaRequired ||
        decision == null ||
        decision.isCompleted ||
        !_current(_generation) ||
        password.isEmpty ||
        password.length > 4096 ||
        password.contains('\u0000')) {
      return;
    }
    decision.complete(password);
  }

  void pointer(RdpPointerEvent event) {
    if (phase != RdpSessionPhase.connected ||
        !event.valid ||
        !_current(_generation)) {
      return;
    }
    _channel?.pointer(event);
  }

  void key(RdpKeyEvent event) {
    if (phase != RdpSessionPhase.connected ||
        !event.valid ||
        !_current(_generation)) {
      return;
    }
    _channel?.key(event);
  }

  void synchronize() {
    if (!_current(_generation)) retire();
  }

  void retire() {
    if (_retired || _disposed) return;
    _finish(retired: true);
  }

  @override
  void dispose() {
    _disposed = true;
    _retired = true;
    _generation++;
    _closeResources();
    super.dispose();
  }
}
