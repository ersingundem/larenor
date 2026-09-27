import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cooking_timers_controller.dart';

/// Foreground cooking alerts with durable at-most-once delivery.
///
/// The receipt is persisted before device feedback so process restarts never
/// repeat an alert whose delivery outcome is unknown.
final class DurableCookingTimerNotifications
    implements CookingTimerNotifications {
  DurableCookingTimerNotifications({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  static const _key = 'cooking_timer_notification_receipts_v1';
  static const _maximumReceipts = 256;
  final Future<SharedPreferences> Function() _preferences;
  Future<void> _serial = Future.value();

  @override
  Future<void> finished({
    required String idempotencyKey,
    required String label,
  }) {
    final operation = _serial.then((_) async {
      final preferences = await _preferences();
      final receipts = preferences.getStringList(_key) ?? const <String>[];
      if (receipts.contains(idempotencyKey)) return;
      final updated = <String>[...receipts, idempotencyKey];
      if (updated.length > _maximumReceipts) {
        updated.removeRange(0, updated.length - _maximumReceipts);
      }
      if (!await preferences.setStringList(_key, updated)) {
        throw StateError('cooking_timer_notification_storage_unavailable');
      }
      try {
        await SystemSound.play(SystemSoundType.alert);
        await HapticFeedback.vibrate();
      } catch (_) {
        // The durable receipt is authoritative; unavailable device feedback
        // must not turn into a duplicate alert on resume.
      }
    });
    _serial = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}
