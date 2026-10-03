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

enum RdpClipboardSendResult { submitted, empty, invalid, unavailable, failed }

class RdpSessionController extends ChangeNotifier {
  RdpSessionController({
    required this.profile,
    required this.trust,
    required this.engineFactory,
    required this.isCurrent,
    required this.display,
    this.credentialVault,
    this.settings = const RdpProfileSettings(),
    this.remoteAudio = false,
    this.connectTimeout = const Duration(seconds: 45),
  });
  final RemoteProfile profile;
  final RdpTrustStore trust;
  final RdpEngine Function() engineFactory;
  final bool Function() isCurrent;
  final RdpDisplaySpec display;
  final RdpCredentialVault? credentialVault;
  final RdpProfileSettings settings;
  final bool remoteAudio;
  final Duration connectTimeout;

  RdpSessionPhase phase = RdpSessionPhase.idle;
  RdpCapabilities? capabilities;
  RdpCertificatePin? pendingCertificate;
  String? error;
  bool supportsUnicodeInput = false;
  bool supportsRelativePointer = false;
  RdpAudioObservation? audioObservation;
  Timer? _audioTimer;
  RdpAudioRead? _audioRead;
  RdpFrameGeometry? _acknowledgedGeometry;
  int _displayGeneration = 0, _displayLayoutRevision = 1;
  RdpDisplaySpec? _requestedDisplay;
  RdpDisplaySpec get requestedDisplay => _requestedDisplay ?? display;
  bool get canSendPointer =>
      _acknowledgedGeometry != null &&
      phase == RdpSessionPhase.connected &&
      _current(_generation);
  bool get hasSensitiveInput => _passwordDecision != null;
  bool get canSendClipboard =>
      phase == RdpSessionPhase.connected &&
      settings.clipboardMode == RdpClipboardMode.clientToRemote &&
      capabilities?.supportedClipboardModes.contains(
            RdpClipboardMode.clientToRemote,
          ) ==
          true &&
      _channel != null &&
      _current(_generation);
  Stream<RdpFrame> get frames => _channel is RdpFrameChannel
      ? (_channel! as RdpFrameChannel).frames
      : const Stream<RdpFrame>.empty();

  Future<bool> acknowledgeFrame(RdpFrame frame) async {
    final channel = _channel;
    final generation = _generation, displayGeneration = _displayGeneration;
    if (phase != RdpSessionPhase.connected ||
        channel is! RdpFrameChannel ||
        !_current(generation) ||
        !frame.geometry.valid) {
      return false;
    }
    final accepted = await channel.acknowledgeFrame(frame.sequence);
    if (!accepted ||
        !_current(generation) ||
        !identical(channel, _channel) ||
        phase != RdpSessionPhase.connected) {
      return false;
    }
    final requested = requestedDisplay;
    _acknowledgedGeometry =
        displayGeneration == _displayGeneration &&
            frame.displayLayoutRevision == _displayLayoutRevision &&
            frame.width == requested.width &&
            frame.height == requested.height
        ? frame.geometry
        : null;
    return true;
  }

  RdpEngine? _engine;
  RdpChannel? _channel;
  Completer<bool>? _certificateDecision;
  Completer<RdpCredential?>? _passwordDecision;
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
    if (!_current(generation)) throw const RdpFailure('retired');
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _closeResources() {
    _audioRead?.cancel();
    _audioRead = null;
    _audioTimer?.cancel();
    _audioTimer = null;
    audioObservation = null;
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
    if (_opening?.isCompleted == false) {
      _opening!.complete();
    }
    _opening = null;
    pendingCertificate = null;
    _channel?.close();
    _channel = null;
    supportsUnicodeInput = false;
    supportsRelativePointer = false;
    _acknowledgedGeometry = null;
    _displayGeneration++;
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
    supportsUnicodeInput = false;
    supportsRelativePointer = false;
    _acknowledgedGeometry = null;
    _displayLayoutRevision = 1;
    _requestedDisplay = display;
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
                code: value is RdpFailure ? value.code : 'connection_failed',
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
      phase = RdpSessionPhase.unsupported;
      _publish();
      return;
    }
    if (!found.supportsNla) {
      throw const RdpFailure('nla_unsupported');
    }
    if (remoteAudio && !found.supportsAudio) {
      throw const RdpFailure('audio_unavailable');
    }
    await trust.checkProfile(profile, isCurrent: () => _current(generation));
    final probe = await engine.inspect(
      profile,
      isCurrent: () => _current(generation),
    );
    _check(generation);
    probe.certificate.validate();
    if (!probe.tlsCertificateObserved) {
      throw const RdpFailure('tls_required');
    }
    if (!probe.clientRequiresNla) throw const RdpFailure('invalid_response');
    final pinned = await trust.readPin(
      profile,
      isCurrent: () => _current(generation),
    );
    _check(generation);
    if (pinned != null && pinned != probe.certificate) {
      throw const RdpFailure('certificate_changed');
    }
    if (pinned == null) {
      final decision = _certificateDecision = Completer<bool>();
      pendingCertificate = probe.certificate;
      phase = RdpSessionPhase.certificate;
      _publish();
      if (!await decision.future) {
        throw const RdpFailure('certificate_rejected');
      }
      _check(generation);
      _certificateDecision = null;
      pendingCertificate = null;
    }
    var credential = await credentialVault?.readCredential(
      profile,
      isCurrent: () => _current(generation),
    );
    _check(generation);
    if (credential == null) {
      final decision = _passwordDecision = Completer<RdpCredential?>();
      phase = RdpSessionPhase.nlaRequired;
      _publish();
      credential = await decision.future;
      _passwordDecision = null;
      _check(generation);
      if (credential == null) throw const RdpFailure('nla_cancelled');
    }
    phase = RdpSessionPhase.connecting;
    _publish();
    final request = RdpSessionRequest(
      profile: profile,
      display: display,
      certificateFingerprint: probe.certificate.fingerprint,
      settings: settings,
      channels: RdpChannelPolicy(
        clipboard: settings.clipboardMode != RdpClipboardMode.disabled,
        audio: remoteAudio,
      ),
    );
    request.validate(found);
    final channel = await engine.open(
      request,
      credential: credential,
      isCurrent: () => _current(generation),
    );
    credential = null;
    if (!_current(generation)) {
      channel.close();
      _check(generation);
    }
    _channel = channel;
    if (remoteAudio && channel is! RdpAudioPlaybackChannel) {
      throw const RdpFailure('audio_unavailable');
    }
    supportsUnicodeInput =
        channel is RdpNegotiatedInputChannel && channel.supportsUnicodeInput;
    supportsRelativePointer =
        channel is RdpNegotiatedInputChannel &&
        found.supportsRelativePointerNegotiation &&
        channel.supportsRelativePointer;
    _timer?.cancel();
    _timer = null;
    phase = RdpSessionPhase.connected;
    _publish();
    if (remoteAudio) unawaited(_readAudio(generation, channel));
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

  Future<void> _readAudio(int generation, RdpChannel channel) async {
    if (!_current(generation)) {
      if (generation == _generation && !_disposed) retire();
      return;
    }
    if (phase != RdpSessionPhase.connected ||
        !identical(channel, _channel) ||
        channel is! RdpAudioPlaybackChannel) {
      return;
    }
    try {
      final read = _audioRead = RdpAudioRead(channel.audioObservation());
      final value = await read.future;
      if (identical(_audioRead, read)) _audioRead = null;
      if (!_current(generation)) {
        if (generation == _generation && !_disposed) retire();
        return;
      }
      if (!identical(channel, _channel)) return;
      final previous = audioObservation;
      if (previous != null && !value.follows(previous)) {
        throw const RdpFailure('invalid_response');
      }
      audioObservation = value;
      if (value != previous) _publish();
      if (_current(generation) &&
          phase == RdpSessionPhase.connected &&
          value.state != RdpAudioState.failed) {
        // Schedule after the bounded read settles; never overlap observations
        // or send an audio command, replay, or reconnect from this readback.
        _audioTimer = Timer(const Duration(seconds: 1), () {
          _audioTimer = null;
          unawaited(_readAudio(generation, channel));
        });
      }
    } catch (value) {
      if (_current(generation) && identical(channel, _channel)) {
        _finish(code: value is RdpFailure ? value.code : 'audio_unavailable');
      } else if (generation == _generation && !_disposed) {
        retire();
      }
    }
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

  Future<void> authenticate(
    String password, {
    String gatewayPassword = '',
    bool remember = false,
  }) async {
    final generation = _generation;
    final decision = _passwordDecision;
    if (phase != RdpSessionPhase.nlaRequired ||
        decision == null ||
        decision.isCompleted ||
        !_current(_generation) ||
        password.isEmpty) {
      return;
    }
    try {
      final credential = RdpCredential(
        password: password,
        gatewayPassword: gatewayPassword,
      );
      credential.validate();
      if (remember) {
        final vault = credentialVault;
        if (vault == null) throw const RdpFailure('storage_failed');
        await vault.saveCredential(
          profile,
          credential,
          isCurrent: () => _current(generation),
        );
        _check(generation);
      }
      if (!decision.isCompleted) decision.complete(credential);
    } catch (value) {
      if (generation == _generation) {
        _finish(code: value is RdpFailure ? value.code : 'storage_failed');
      }
    }
  }

  Future<void> reconnect() async {
    if (_disposed ||
        _retired ||
        phase != RdpSessionPhase.failed && phase != RdpSessionPhase.closed) {
      return;
    }
    phase = RdpSessionPhase.idle;
    error = null;
    _publish();
    await connect();
  }

  void disconnect() {
    if (_disposed || _retired || phase != RdpSessionPhase.connected) return;
    _finish();
  }

  void resize(RdpDisplaySpec next) {
    final found = capabilities;
    if (phase != RdpSessionPhase.connected ||
        found == null ||
        !found.supportsDynamicResolution ||
        !found.acceptsDisplay(next) ||
        next == requestedDisplay ||
        !_current(_generation)) {
      return;
    }
    if (_displayLayoutRevision >= 9007199254740991) {
      retire();
      return;
    }
    _requestedDisplay = next;
    _displayLayoutRevision++;
    _displayGeneration++;
    _acknowledgedGeometry = null;
    _channel?.resize(next);
  }

  void pointer(RdpPointerEvent event) {
    if (phase != RdpSessionPhase.connected ||
        capabilities?.supportsAbsolutePointer != true ||
        !event.valid ||
        event.geometry != _acknowledgedGeometry ||
        !_current(_generation)) {
      return;
    }
    _channel?.pointer(event);
  }

  void relativePointer(RdpRelativePointerEvent event) {
    if (!supportsRelativePointer ||
        !canSendPointer ||
        !event.valid ||
        event.geometry != _acknowledgedGeometry) {
      return;
    }
    _channel?.relativePointer(event);
  }

  void wheel(RdpWheelEvent event) {
    if (capabilities?.supportsVerticalWheel != true ||
        !canSendPointer ||
        !event.valid ||
        event.geometry != _acknowledgedGeometry) {
      return;
    }
    _channel?.wheel(event);
  }

  void key(RdpKeyEvent event) {
    if (phase != RdpSessionPhase.connected ||
        !event.supported ||
        !_current(_generation)) {
      return;
    }
    _channel?.key(event);
  }

  void text(String value) {
    if (phase != RdpSessionPhase.connected ||
        !supportsUnicodeInput ||
        !validRdpImeText(value) ||
        !_current(_generation)) {
      return;
    }
    _channel?.text(value);
  }

  Future<RdpClipboardSendResult> sendClipboardFrom(
    Future<String?> Function() read,
  ) async {
    if (!canSendClipboard) return RdpClipboardSendResult.unavailable;
    final generation = _generation, channel = _channel!;
    try {
      final value = await read().timeout(const Duration(seconds: 5));
      if (!_current(generation) ||
          !identical(channel, _channel) ||
          !canSendClipboard) {
        return RdpClipboardSendResult.unavailable;
      }
      if (value == null || value.isEmpty) return RdpClipboardSendResult.empty;
      if (!validRdpClipboardText(value)) return RdpClipboardSendResult.invalid;
      final submitted = await channel
          .sendClipboardText(value)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              channel.close();
              return false;
            },
          );
      if (!_current(generation) ||
          !identical(channel, _channel) ||
          !canSendClipboard) {
        return RdpClipboardSendResult.unavailable;
      }
      return submitted
          ? RdpClipboardSendResult.submitted
          : RdpClipboardSendResult.failed;
    } catch (_) {
      return _current(generation) && identical(channel, _channel)
          ? RdpClipboardSendResult.failed
          : RdpClipboardSendResult.unavailable;
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
}
