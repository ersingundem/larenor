import 'dart:async';

import '../../settings/data/pin_lock_store.dart';
import '../domain/kiosk_models.dart';
import 'kiosk_api.dart';

/// PIN verification stays in the device secure-store boundary. The native bridge
/// adds a separate one-use monotonic deadline and fresh device-policy checks.
class KioskController {
  KioskController(this.api, this.pinStore);
  final KioskApi api;
  final PinLockStore pinStore;
  KioskIntent? _intent;
  bool _busy = false, _closed = false;
  int _generation = 0;
  Future<KioskSnapshot> snapshot() => api.snapshot();
  Future<KioskIntent> prepare(
    KioskAction action, {
    required bool Function() isCurrent,
  }) async {
    if (_busy || _intent != null) throw const KioskException(KioskFailure.busy);
    final generation = _generation;
    void current() {
      if (_closed || generation != _generation || !isCurrent()) {
        throw const KioskException(KioskFailure.expired);
      }
    }

    current();
    _busy = true;
    try {
      final pin = await pinStore.read();
      current();
      if (pin == null || !RegExp(r'^\d{4,12}$').hasMatch(pin)) {
        throw const KioskException(KioskFailure.pinRequired);
      }
      final intent = await api.prepare(action);
      if (_closed || generation != _generation || !isCurrent()) {
        await api.cancel(intent);
        throw const KioskException(KioskFailure.expired);
      }
      _intent = intent;
      return intent;
    } on KioskException {
      rethrow;
    } catch (_) {
      throw const KioskException(KioskFailure.unavailable);
    } finally {
      _busy = false;
    }
  }

  Future<KioskReceipt> execute(
    KioskIntent intent,
    String pin, {
    required bool Function() isCurrent,
  }) async {
    if (_busy) throw const KioskException(KioskFailure.busy);
    if (_closed || !identical(_intent, intent) || !isCurrent()) {
      throw const KioskException(KioskFailure.expired);
    }
    _intent = null;
    _busy = true;
    final generation = _generation;
    void current() {
      if (_closed || generation != _generation || !isCurrent()) {
        throw const KioskException(KioskFailure.expired);
      }
    }

    try {
      current();
      final before = await pinStore.read();
      current();
      if (before == null || !RegExp(r'^\d{4,12}$').hasMatch(before)) {
        throw const KioskException(KioskFailure.pinRequired);
      }
      final result = await pinStore.verify(pin);
      current();
      if (!result.accepted) {
        throw KioskException(
          result.retryAfter > Duration.zero
              ? KioskFailure.rateLimited
              : KioskFailure.wrongPin,
          retryAfter: result.retryAfter,
        );
      }
      final after = await pinStore.read();
      current();
      if (after != before) throw const KioskException(KioskFailure.expired);
      try {
        return await api.execute(intent);
      } on KioskException catch (error) {
        if (error.failure == KioskFailure.denied ||
            error.failure == KioskFailure.expired ||
            error.failure == KioskFailure.busy ||
            error.failure == KioskFailure.unsupported) {
          rethrow;
        }
        return const KioskReceipt(KioskOutcome.unknown, null);
      } catch (_) {
        return const KioskReceipt(KioskOutcome.unknown, null);
      }
    } on KioskException {
      rethrow;
    } catch (_) {
      throw const KioskException(KioskFailure.unavailable);
    } finally {
      _busy = false;
      unawaited(_cancel(intent));
    }
  }

  Future<void> _cancel(KioskIntent intent) async {
    try {
      await api.cancel(intent);
    } catch (_) {
      /* Monotonic native expiry remains. */
    }
  }

  void invalidate() {
    _generation++;
    final intent = _intent;
    _intent = null;
    if (intent != null) unawaited(_cancel(intent));
  }

  void dispose() {
    _closed = true;
    invalidate();
  }
}
