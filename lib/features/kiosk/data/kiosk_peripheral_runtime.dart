import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/kiosk_peripheral_contract.dart';

@immutable
final class KioskPeripheralRuntimeSnapshot {
  const KioskPeripheralRuntimeSnapshot({
    required this.rawInventory,
    required this.authority,
    required this.gmsAvailable,
  });

  final Object? rawInventory;
  final KioskPeripheralAuthority? authority;
  final bool gmsAvailable;
}

abstract interface class KioskPeripheralRuntime {
  Future<KioskPeripheralRuntimeSnapshot> snapshot();
  Future<Object?> takeNextInput(String providerId);
  int nowElapsedMs();
}

/// Read-only adapter boundary. No peripheral worker is advertised yet.
final class AndroidKioskPeripheralRuntime implements KioskPeripheralRuntime {
  AndroidKioskPeripheralRuntime({MethodChannel? channel, bool? isAndroid})
    : _channel =
          channel ??
          const MethodChannel('com.ersingundem.larenor/kiosk_peripherals'),
      _isAndroid = isAndroid ?? defaultTargetPlatform == TargetPlatform.android;

  final MethodChannel _channel;
  final bool _isAndroid;

  @override
  Future<KioskPeripheralRuntimeSnapshot> snapshot() async {
    if (!_isAndroid) return _unavailable();
    try {
      final raw = await _channel.invokeMethod<Object?>('capabilities');
      // The native stub has no trusted device/session authority or input worker.
      // It can only advertise unavailable capabilities for tablet settings.
      final inventory = KioskPeripheralInventory.fromChannel(
        raw,
        gmsAvailable: false,
      );
      if (inventory.providers.any((provider) => provider.supported)) {
        return _unavailable();
      }
      return KioskPeripheralRuntimeSnapshot(
        rawInventory: raw,
        authority: null,
        gmsAvailable: false,
      );
    } catch (_) {
      return _unavailable();
    }
  }

  @override
  Future<Object?> takeNextInput(String providerId) async => null;

  @override
  int nowElapsedMs() => 0;
}

KioskPeripheralRuntimeSnapshot _unavailable() => KioskPeripheralRuntimeSnapshot(
  rawInventory: {
    'schemaVersion': 1,
    'inventoryRevision': 1,
    'providers': [
      for (final kind in KioskPeripheralKind.values)
        {
          'providerId': '${kind.name}.unavailable',
          'kind': kind.name,
          'revision': 1,
          'supported': false,
          'enabledByUser': false,
          'permission': 'unknown',
          'connected': false,
          'requiresGms': false,
          'maxPayloadBytes': switch (kind) {
            KioskPeripheralKind.tts || KioskPeripheralKind.print => 0,
            _ => 1,
          },
        },
    ],
  },
  authority: null,
  gmsAvailable: false,
);

abstract interface class KioskPeripheralOptInStore {
  Future<Set<String>> read();
  Future<void> save(Set<String> ids);
}

final class LocalKioskPeripheralOptInStore
    implements KioskPeripheralOptInStore {
  const LocalKioskPeripheralOptInStore();

  static const _preferenceName = 'kiosk_peripheral_opt_in_v1';

  @override
  Future<Set<String>> read() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    return preferences.getStringList(_preferenceName)?.toSet() ?? {};
  }

  @override
  Future<void> save(Set<String> ids) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setStringList(
      _preferenceName,
      ids.toList()..sort(),
    )) {
      throw StateError('peripheral_opt_in_unavailable');
    }
  }
}
