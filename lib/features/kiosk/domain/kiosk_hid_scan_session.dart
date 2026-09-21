import 'dart:convert';

import 'package:crypto/crypto.dart';

enum HidScanState {
  inactive,
  scanning,
  captured,
  duplicate,
  invalid,
  tooLong,
  expired,
}

/// A local, explicitly enabled HID reader session. No URL, JS, command or
/// backend handoff exists in this contract; reviewed data lives in RAM only.
final class KioskHidScanSession {
  static const maxLength = 128;
  static const idleLimit = Duration(seconds: 15);
  static const sessionLimit = Duration(minutes: 2);
  static const duplicateWindow = Duration(seconds: 2);

  HidScanState state = HidScanState.inactive;
  String _buffer = '';
  String? _captured;
  bool _revealed = false;
  DateTime? _startedAt, _lastInputAt, _lastAcceptedAt;
  String? _lastDigest;

  int get length => _captured?.length ?? _buffer.length;
  String? get reviewedValue =>
      state == HidScanState.captured && _revealed ? _captured : null;

  void start(DateTime now) {
    _buffer = '';
    _captured = null;
    _revealed = false;
    _startedAt = now;
    _lastInputAt = now;
    state = HidScanState.scanning;
  }

  void feed(String? character, DateTime now) {
    if (state != HidScanState.scanning) return;
    expire(now);
    if (state != HidScanState.scanning || character == null) return;
    if (character.length != 1 ||
        character.codeUnitAt(0) < 32 ||
        character.codeUnitAt(0) > 126) {
      _reject(HidScanState.invalid);
      return;
    }
    if (_buffer.length >= maxLength) {
      _reject(HidScanState.tooLong);
      return;
    }
    _buffer += character;
    _lastInputAt = now;
  }

  void finish(DateTime now) {
    if (state != HidScanState.scanning) return;
    expire(now);
    if (state != HidScanState.scanning) return;
    if (_buffer.trim().isEmpty) {
      _reject(HidScanState.invalid);
      return;
    }
    final digest = sha256.convert(utf8.encode(_buffer)).toString();
    final previous = _lastAcceptedAt;
    if (_lastDigest == digest &&
        previous != null &&
        !now.isBefore(previous) &&
        now.difference(previous) < duplicateWindow) {
      _reject(HidScanState.duplicate);
      return;
    }
    _captured = _buffer;
    _buffer = '';
    _lastDigest = digest;
    _lastAcceptedAt = now;
    _lastInputAt = now;
    state = HidScanState.captured;
  }

  void reveal() {
    if (state == HidScanState.captured) _revealed = true;
  }

  void expire(DateTime now) {
    if (state != HidScanState.scanning && state != HidScanState.captured) {
      return;
    }
    final started = _startedAt;
    final last = _lastInputAt;
    if (started == null ||
        last == null ||
        now.isBefore(started) ||
        now.isBefore(last) ||
        now.difference(started) >= sessionLimit ||
        now.difference(last) >= idleLimit) {
      _reject(HidScanState.expired);
    }
  }

  void stop() {
    _reject(HidScanState.inactive);
    _lastDigest = null;
    _lastAcceptedAt = null;
  }

  void _reject(HidScanState next) {
    _buffer = '';
    _captured = null;
    _revealed = false;
    _startedAt = null;
    _lastInputAt = null;
    state = next;
  }

  @override
  String toString() => 'KioskHidScanSession(${state.name})';
}
