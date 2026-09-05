import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/kiosk_models.dart';

abstract class KioskApi {
  Future<KioskSnapshot> snapshot();
  Future<KioskIntent> prepare(KioskAction action);
  Future<KioskReceipt> execute(KioskIntent intent);
  Future<void> cancel(KioskIntent intent);
}

class AndroidKioskApi extends KioskApi {
  AndroidKioskApi({MethodChannel? channel, bool? isAndroid})
    : _channel =
          channel ?? const MethodChannel('com.ersingundem.larenor/kiosk'),
      _android =
          isAndroid ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  final MethodChannel _channel;
  final bool _android;
  Future<Object?> _call(String method, [Object? args]) async {
    if (!_android) throw const KioskException(KioskFailure.unsupported);
    try {
      return await _channel
          .invokeMethod<Object?>(method, args)
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw const KioskException(KioskFailure.unavailable);
    } on MissingPluginException {
      throw const KioskException(KioskFailure.unsupported);
    } on PlatformException catch (e) {
      throw KioskException(switch (e.code) {
        'expired' => KioskFailure.expired,
        'busy' => KioskFailure.busy,
        'denied' => KioskFailure.denied,
        _ => KioskFailure.unavailable,
      });
    }
  }

  @override
  Future<KioskSnapshot> snapshot() async {
    if (!_android) return KioskSnapshot(supported: false);
    return KioskSnapshot.fromChannel(await _call('snapshot'));
  }

  @override
  Future<KioskIntent> prepare(KioskAction action) async =>
      KioskIntent.fromChannel(
        await _call('prepare', {'action': action.name}),
        action,
      );
  @override
  Future<KioskReceipt> execute(KioskIntent intent) async {
    try {
      return KioskReceipt.fromChannel(
        await _call('execute', {'id': intent.id}),
      );
    } on KioskException catch (e) {
      if (e.failure == KioskFailure.expired ||
          e.failure == KioskFailure.denied ||
          e.failure == KioskFailure.busy ||
          e.failure == KioskFailure.unsupported) {
        rethrow;
      }
      // An unreadable response after dispatch is not proof that no policy changed.
      return const KioskReceipt(KioskOutcome.unknown, null);
    } catch (_) {
      return const KioskReceipt(KioskOutcome.unknown, null);
    }
  }

  @override
  Future<void> cancel(KioskIntent intent) async {
    try {
      await _call('cancel', {'id': intent.id});
    } catch (_) {
      /* Native expiry remains in force. */
    }
  }
}
