import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/remote_profiles.dart';
import 'vnc_engine.dart';
import 'vnc_models.dart';
import 'vnc_security_store.dart';

enum VncSessionPhase {
  idle,
  checking,
  unsupported,
  certificate,
  passwordRequired,
  connecting,
  connected,
  closed,
  failed,
}

class VncSessionController extends ChangeNotifier {
  VncSessionController({
    required this.profile,
    required this.trust,
    required this.engineFactory,
    required this.isCurrent,
    required this.display,
    this.connectTimeout = const Duration(seconds: 45),
  });
  final RemoteProfile profile;
  final VncTrustStore trust;
  final VncEngine Function() engineFactory;
  final bool Function() isCurrent;
  final VncDisplaySpec display;
  final Duration connectTimeout;

  VncSessionPhase phase = VncSessionPhase.idle;
  VncCapabilities? capabilities;
  VncCertificatePin? pendingCertificate;
  String? error;
  bool get hasSensitiveInput => _passwordDecision != null;

  VncEngine? _engine;
  VncChannel? _channel;
  Completer<bool>? _certificateDecision;
  Completer<VncEphemeralSecret?>? _passwordDecision;
  Completer<void>? _opening;
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
    if (!_current(generation)) throw const VncFailure('retired');
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
    if (_opening?.isCompleted == false) _opening!.complete();
    _opening = null;
    pendingCertificate = null;
    final channel = _channel;
    _channel = null;
    channel?.close();
    final engine = _engine;
    _engine = null;
    engine?.close();
  }

  void _finish({String? code, bool retired = false}) {
    _generation++;
    _retired = _retired || retired;
    _closeResources();
    error = code;
    phase = retired || code == null
        ? VncSessionPhase.closed
        : VncSessionPhase.failed;
    _publish();
  }

  Future<void> connect() {
    if (phase != VncSessionPhase.idle || _retired || _disposed) {
      return Future.value();
    }
    if (!_current(_generation)) {
      retire();
      return Future.value();
    }
    final generation = ++_generation;
    phase = VncSessionPhase.checking;
    error = null;
    capabilities = null;
    _engine = engineFactory();
    _timer = Timer(connectTimeout, () {
      if (generation == _generation) _finish(code: 'timed_out');
    });
    final opening = _opening = Completer<void>();
    _publish();
    unawaited(
      _start(generation).then(
        (_) {
          if (!opening.isCompleted) opening.complete();
          if (identical(_opening, opening)) _opening = null;
        },
        onError: (Object value) {
          if (generation == _generation && !_disposed) {
            if (!_current(generation)) {
              _finish(retired: true);
            } else {
              _finish(
                code: value is VncFailure ? value.code : 'connection_failed',
              );
            }
          }
          if (!opening.isCompleted) opening.complete();
          if (identical(_opening, opening)) _opening = null;
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
      phase = VncSessionPhase.unsupported;
      _publish();
      return;
    }
    await trust.checkProfile(profile, isCurrent: () => _current(generation));
    _check(generation);
    final negotiation = await engine.negotiate(
      profile,
      isCurrent: () => _current(generation),
    );
    _check(generation);
    negotiation.validate(VncTransportPolicy.lockedDown);
    if (!found.supportedVersions.contains(negotiation.version) ||
        !found.supportedSecurity.contains(negotiation.securityType)) {
      throw const VncFailure('security_unsupported');
    }
    final certificate = negotiation.certificate!;
    final pinned = await trust.readPin(
      profile,
      isCurrent: () => _current(generation),
    );
    _check(generation);
    if (pinned != null && pinned != certificate) {
      throw const VncFailure('certificate_changed');
    }
    if (pinned == null) {
      final decision = _certificateDecision = Completer<bool>();
      pendingCertificate = certificate;
      phase = VncSessionPhase.certificate;
      _publish();
      if (!await decision.future) {
        throw const VncFailure('certificate_rejected');
      }
      _check(generation);
      _certificateDecision = null;
      pendingCertificate = null;
    }
    VncEphemeralSecret? secret;
    VncSecretLease? lease;
    if (negotiation.requiresPassword) {
      final decision = _passwordDecision = Completer<VncEphemeralSecret?>();
      phase = VncSessionPhase.passwordRequired;
      _publish();
      secret = await decision.future;
      _passwordDecision = null;
      _check(generation);
      if (secret == null) throw const VncFailure('password_cancelled');
      lease = secret.consume();
      secret = null;
    }
    phase = VncSessionPhase.connecting;
    _publish();
    final request = VncSessionRequest(
      profile: profile,
      display: display,
      securityType: negotiation.securityType,
      certificateFingerprint: certificate.fingerprint,
    );
    request.validate(found);
    VncChannel channel;
    try {
      channel = await engine.open(
        request,
        password: lease,
        isCurrent: () => _current(generation),
      );
    } finally {
      lease?.dispose();
      secret?.dispose();
    }
    if (!_current(generation)) {
      channel.close();
      _check(generation);
    }
    _channel = channel;
    _timer?.cancel();
    _timer = null;
    phase = VncSessionPhase.connected;
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
    if (phase != VncSessionPhase.certificate ||
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
        _finish(code: value is VncFailure ? value.code : 'storage_failed');
      }
    }
  }

  Future<void> authenticate(String password) async {
    final decision = _passwordDecision;
    if (phase != VncSessionPhase.passwordRequired ||
        decision == null ||
        decision.isCompleted ||
        !_current(_generation)) {
      return;
    }
    try {
      decision.complete(VncEphemeralSecret.fromText(password));
    } on VncFailure {
      return;
    }
  }

  void pointer(VncPointerEvent event) {
    if (phase == VncSessionPhase.connected &&
        event.valid &&
        _current(_generation)) {
      _channel?.pointer(event);
    }
  }

  void key(VncKeyEvent event) {
    if (phase == VncSessionPhase.connected &&
        event.valid &&
        _current(_generation)) {
      _channel?.key(event);
    }
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

  @override
  String toString() => 'VncSessionController(${phase.name})';
}
