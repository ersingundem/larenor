import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/remote_profiles.dart';
import 'ssh_security_store.dart';
import 'ssh_engine.dart';

enum SshSessionPhase {
  idle,
  connecting,
  hostKey,
  challenge,
  connected,
  closed,
  failed,
}

class SshSessionController extends ChangeNotifier {
  SshSessionController({
    required this.profile,
    this.jumpProfile,
    required this.store,
    required this.engineFactory,
    required this.isCurrent,
    this.connectTimeout = const Duration(seconds: 45),
    this.initialSize = SshTerminalSize.standard,
  });
  final RemoteProfile profile;
  final RemoteProfile? jumpProfile;
  final SshSecurityStore store;
  final SshEngine Function() engineFactory;
  final bool Function() isCurrent;
  final Duration connectTimeout;
  final SshTerminalSize initialSize;
  SshSessionPhase phase = SshSessionPhase.idle;
  SshHostPin? pendingPin;
  SshHop? pendingHop;
  SshHop? failureHop;
  SshAuthChallenge? pendingChallenge;
  String? error;
  String transcript = '';

  SshEngine? _engine;
  SshChannel? _channel;
  final _subscriptions = <StreamSubscription<String>>[];
  Completer<bool>? _decision;
  Completer<List<String>?>? _challengeDecision;
  Completer<void>? _opening;
  Timer? _timer;
  int _generation = 0;
  bool _retired = false, _disposed = false, _sending = false;
  late SshTerminalSize _terminalSize = initialSize;
  SshTerminalSize? _sentSize;
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
    if (!_current(generation)) throw const SshFailure('retired');
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _closeResources() {
    _timer?.cancel();
    _timer = null;
    if (_decision?.isCompleted == false) _decision!.complete(false);
    _decision = null;
    pendingPin = null;
    pendingHop = null;
    pendingChallenge = null;
    if (_challengeDecision?.isCompleted == false) {
      _challengeDecision!.complete(null);
    }
    _challengeDecision = null;
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
    _channel?.close();
    _channel = null;
    _engine?.close();
    _engine = null;
    if (_opening?.isCompleted == false) _opening!.complete();
    _opening = null;
    _sending = false;
    _sentSize = null;
  }

  void _end({String? code, bool clear = true}) {
    _generation++;
    _closeResources();
    error = code;
    phase = code == null ? SshSessionPhase.closed : SshSessionPhase.failed;
    if (clear) transcript = '';
    _publish();
  }

  @override
  void dispose() {
    _disposed = true;
    _retired = true;
    _generation++;
    _closeResources();
    transcript = '';
    super.dispose();
  }

  @override
  String toString() => 'SshSessionController(${phase.name})';
  Future<void> connect() {
    if (_retired ||
        _disposed ||
        phase == SshSessionPhase.connecting ||
        phase == SshSessionPhase.hostKey ||
        phase == SshSessionPhase.challenge ||
        phase == SshSessionPhase.connected) {
      return Future.value();
    }
    if (!_current(_generation)) {
      retire();
      return Future.value();
    }
    _generation++;
    final generation = _generation;
    _closeResources();
    phase = SshSessionPhase.connecting;
    error = null;
    failureHop = null;
    transcript = '';
    _publish();
    final finished = Completer<void>();
    _opening = finished;
    _timer = Timer(connectTimeout, () {
      if (generation == _generation) _end(code: 'timed_out');
    });
    unawaited(
      _start(generation).then(
        (_) {
          if (!finished.isCompleted) finished.complete();
        },
        onError: (Object e) {
          if (generation == _generation && !_disposed) {
            if (!_current(generation)) {
              retire();
            } else {
              if (e is SshFailure) {
                if (e.code.startsWith('jump_')) {
                  failureHop = SshHop.jump;
                } else if (e.code.startsWith('target_')) {
                  failureHop = SshHop.target;
                }
              }
              _end(code: e is SshFailure ? e.code : 'connection_failed');
            }
          }
          if (!finished.isCompleted) finished.complete();
        },
      ),
    );
    return finished.future;
  }

  Future<void> _start(int generation) async {
    bool current() => _current(generation);
    await store.checkProfile(profile, isCurrent: current);
    _check(generation);
    final credential = await store.readCredential(profile, isCurrent: current);
    _check(generation);
    if (credential == null) throw const SshFailure('credential_missing');
    SshJumpConnection? jump;
    if (jumpProfile case final jumpTarget?) {
      if (jumpTarget.id == profile.id) throw const SshFailure('invalid_jump');
      failureHop = SshHop.jump;
      await store.checkProfile(jumpTarget, isCurrent: current);
      final jumpCredential = await store.readCredential(
        jumpTarget,
        isCurrent: current,
      );
      _check(generation);
      if (jumpCredential == null) {
        throw const SshFailure('jump_credential_missing');
      }
      jump = SshJumpConnection(profile: jumpTarget, credential: jumpCredential);
    }
    final engine = engineFactory();
    _engine = engine;
    _check(generation);
    final channel = await engine.open(
      profile,
      credential,
      isCurrent: current,
      initialSize: _terminalSize,
      jump: jump,
      verifyJumpHost: jump == null
          ? null
          : (pin) => _verifyHost(generation, SshHop.jump, jump!.profile, pin),
      answerChallenge: (hop, challenge) async {
        _check(generation);
        failureHop = hop;
        final decision = _challengeDecision = Completer<List<String>?>();
        pendingHop = hop;
        pendingChallenge = challenge;
        phase = SshSessionPhase.challenge;
        _publish();
        final answer = await decision.future;
        _check(generation);
        pendingChallenge = null;
        pendingHop = null;
        phase = SshSessionPhase.connecting;
        _publish();
        return answer;
      },
      verifyHost: (pin) async {
        return _verifyHost(generation, SshHop.target, profile, pin);
      },
    );
    if (!current()) {
      channel.close();
      _check(generation);
    }
    _channel = channel;
    _sentSize = _terminalSize;
    _timer?.cancel();
    _timer = null;
    pendingPin = null;
    phase = SshSessionPhase.connected;
    var streamsOpen = 2;
    var ended = false;
    void complete() {
      if (ended && streamsOpen == 0 && generation == _generation) {
        _end(clear: false);
      }
    }

    void listen(Stream<List<int>> stream) {
      _subscriptions.add(
        stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(
              (chunk) {
                if (!_current(generation)) {
                  retire();
                  return;
                }
                // Plain text terminal: no ANSI, OSC clipboard, links, or local actions.
                final safe = chunk.replaceAllMapped(
                  RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'),
                  (m) => m[0] == '\x1b' ? '␛' : '',
                );
                transcript += safe;
                if (transcript.length > 65536) {
                  transcript = transcript.substring(transcript.length - 65536);
                }
                _publish();
              },
              onDone: () {
                streamsOpen--;
                complete();
              },
              onError: (Object _) {
                if (generation == _generation) _end(code: 'connection_lost');
              },
            ),
      );
    }

    listen(channel.stdout);
    listen(channel.stderr);
    unawaited(
      channel.done.then(
        (_) {
          ended = true;
          complete();
        },
        onError: (Object _) {
          if (generation == _generation) _end(code: 'connection_lost');
        },
      ),
    );
    _publish();
  }

  Future<bool> _verifyHost(
    int generation,
    SshHop hop,
    RemoteProfile target,
    SshHostPin pin,
  ) async {
    _check(generation);
    failureHop = hop;
    final old = await store.readPin(
      target,
      isCurrent: () => _current(generation),
    );
    _check(generation);
    if (old != null) {
      if (old.type != pin.type || old.fingerprint != pin.fingerprint) {
        throw SshFailure(
          hop == SshHop.jump ? 'jump_host_changed' : 'host_changed',
        );
      }
      return true;
    }
    _decision = Completer<bool>();
    final decision = _decision!;
    pendingPin = pin;
    pendingHop = hop;
    phase = SshSessionPhase.hostKey;
    _publish();
    final accepted = await decision.future;
    _check(generation);
    return accepted;
  }

  Future<void> trustHost() async {
    final generation = _generation,
        decision = _decision,
        pin = pendingPin,
        hop = pendingHop;
    if (phase != SshSessionPhase.hostKey ||
        decision == null ||
        pin == null ||
        hop == null ||
        decision.isCompleted ||
        _sending) {
      return;
    }
    if (!_current(generation)) {
      retire();
      return;
    }
    _sending = true;
    try {
      await store.trust(
        hop == SshHop.jump ? jumpProfile! : profile,
        pin,
        isCurrent: () => _current(generation),
      );
      _check(generation);
      decision.complete(true);
      pendingPin = null;
      pendingHop = null;
      phase = SshSessionPhase.connecting;
      _publish();
    } catch (e) {
      if (generation == _generation) {
        _end(code: e is SshFailure ? e.code : 'storage_failed');
      }
    } finally {
      if (generation == _generation) _sending = false;
    }
  }

  Future<void> answerChallenge(List<String> answers) async {
    final decision = _challengeDecision;
    final challenge = pendingChallenge;
    if (phase != SshSessionPhase.challenge ||
        decision == null ||
        challenge == null ||
        decision.isCompleted ||
        answers.length != challenge.prompts.length ||
        answers.any(
          (value) =>
              value.isEmpty ||
              utf8.encode(value).length > 4096 ||
              value.contains('\u0000'),
        )) {
      return;
    }
    decision.complete(List<String>.of(answers));
  }

  Future<void> sendLine(String line) async {
    if (phase != SshSessionPhase.connected || _sending) return;
    final generation = _generation;
    if (!_current(generation)) {
      retire();
      return;
    }
    if (line.isEmpty ||
        utf8.encode(line).length > 4096 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(line)) {
      error = 'invalid_input';
      _publish();
      return;
    }
    _sending = true;
    try {
      await store
          .checkProfile(profile, isCurrent: () => _current(generation))
          .timeout(const Duration(seconds: 3));
      _check(generation);
      _channel!.write(Uint8List.fromList(utf8.encode('$line\n')));
      error = null;
    } catch (e) {
      if (generation == _generation) {
        _end(code: e is SshFailure ? e.code : 'connection_lost');
      }
    } finally {
      if (generation == _generation) _sending = false;
    }
  }

  void resizeTerminal(SshTerminalSize size) {
    if (!size.isValid) throw const SshFailure('invalid_terminal_size');
    if (_retired || _disposed) return;
    _terminalSize = size;
    if (phase != SshSessionPhase.connected || _channel == null) return;
    if (!_current(_generation)) {
      retire();
      return;
    }
    if (_sentSize == size) return;
    try {
      _channel!.resize(size);
      _sentSize = size;
    } catch (_) {
      _end(code: 'connection_lost');
    }
  }

  void cancel() {
    if (!_disposed) _end();
  }

  void retire() {
    if (_retired || _disposed) return;
    _retired = true;
    _end();
  }
}
