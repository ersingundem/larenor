import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PinAttemptResult {
  const PinAttemptResult({
    required this.accepted,
    this.retryAfter = Duration.zero,
  });

  final bool accepted;
  final Duration retryAfter;
}

/// Device-local protection for Settings. The Keystore/Keychain stores both the
/// PIN and failed-attempt state, so reopening the screen does not reset limits.
/// This is a shared-tablet guard, not a substitute for HA user authorization.
class PinLockStore {
  PinLockStore({FlutterSecureStorage? storage, DateTime Function()? now})
    : _storage = storage ?? const FlutterSecureStorage(),
      _now = now ?? DateTime.now;

  static const _pinKey = 'settings_pin';
  static const _attemptKey = 'settings_pin_attempts';
  final FlutterSecureStorage _storage;
  final DateTime Function() _now;
  Future<void> _pending = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<String?> read() => _storage.read(key: _pinKey);

  Future<void> save(String pin) => _serial(() async {
    if (!RegExp(r'^\d{4,12}$').hasMatch(pin)) {
      throw const FormatException('PIN must contain 4–12 digits.');
    }
    await _storage.write(key: _pinKey, value: pin);
    await _storage.delete(key: _attemptKey);
  });

  Future<void> clear() => _serial(() async {
    await _storage.delete(key: _pinKey);
    await _storage.delete(key: _attemptKey);
  });

  Future<PinAttemptResult> verify(String candidate) => _serial(() async {
    final raw = await _storage.read(key: _attemptKey);
    final attempts = raw == null
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    final failures = (attempts['failures'] as int?) ?? 0;
    final until = (attempts['until'] as int?) ?? 0;
    final now = _now().millisecondsSinceEpoch;
    if (until > now) {
      return PinAttemptResult(
        accepted: false,
        retryAfter: Duration(milliseconds: until - now),
      );
    }
    final pin = await read();
    if (pin == null || candidate == pin) {
      await _storage.delete(key: _attemptKey);
      return const PinAttemptResult(accepted: true);
    }
    final count = failures + 1;
    // Five guesses, then escalating 30/60/120/240/300 second pauses.
    final seconds = count < 5
        ? 0
        : (30 * (1 << (count - 5).clamp(0, 4))).clamp(0, 300);
    await _storage.write(
      key: _attemptKey,
      value: jsonEncode({'failures': count, 'until': now + seconds * 1000}),
    );
    return PinAttemptResult(
      accepted: false,
      retryAfter: Duration(seconds: seconds),
    );
  });
}
