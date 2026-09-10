import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/remote_profiles.dart';
import 'ssh_security_store.dart';
import 'ssh_engine.dart';

enum SshSessionPhase { idle, connecting, hostKey, connected, closed, failed }

class SshSessionController extends ChangeNotifier {
  SshSessionController({
    required this.profile,
    required this.store,
    required this.engineFactory,
    required this.isCurrent,
    this.connectTimeout = const Duration(seconds: 45),
    this.initialSize = SshTerminalSize.standard,
  });
  final RemoteProfile profile;
  final SshSecurityStore store;
  final SshEngine Function() engineFactory;
  final bool Function() isCurrent;
  final Duration connectTimeout;
  final SshTerminalSize initialSize;
  SshSessionPhase phase = SshSessionPhase.idle;
  SshHostPin? pendingPin;
  String? error;
  String transcript = '';

  SshEngine? _engine;
  SshChannel? _channel;
  final _subscriptions = <StreamSubscription<String>>[];
  Completer<bool>? _decision;
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
    final engine = engineFactory();
    _engine = engine;
    _check(generation);
    final channel = await engine.open(
      profile,
      credential,
      isCurrent: current,
      initialSize: _terminalSize,
      verifyHost: (pin) async {
        _check(generation);
        final old = await store.readPin(profile, isCurrent: current);
        _check(generation);
        if (old != null) {
          if (old.type != pin.type || old.fingerprint != pin.fingerprint) {
            throw const SshFailure('host_changed');
          }
          return true;
        }
        _decision = Completer<bool>();
        final decision = _decision!;
        pendingPin = pin;
        phase = SshSessionPhase.hostKey;
        _publish();
        final accepted = await decision.future;
        _check(generation);
        return accepted;
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

  Future<void> trustHost() async {
    final generation = _generation, decision = _decision, pin = pendingPin;
    if (phase != SshSessionPhase.hostKey ||
        decision == null ||
        pin == null ||
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
      await store.trust(profile, pin, isCurrent: () => _current(generation));
      _check(generation);
      decision.complete(true);
      pendingPin = null;
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
