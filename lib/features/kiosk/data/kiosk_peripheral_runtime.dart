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

abstract interface class KioskPeripheralPermissionRuntime {
  Future<bool> requestProviderPermission(String providerId);
}

/// Review-only Android adapter for explicitly armed NFC and external HID input.
final class AndroidKioskPeripheralRuntime
    implements KioskPeripheralRuntime, KioskPeripheralPermissionRuntime {
  AndroidKioskPeripheralRuntime({MethodChannel? channel, bool? isAndroid})
    : _channel =
          channel ??
          const MethodChannel('com.ersingundem.larenor/kiosk_peripherals'),
      _isAndroid = isAndroid ?? defaultTargetPlatform == TargetPlatform.android;

  final MethodChannel _channel;
  final bool _isAndroid;
  KioskPeripheralAuthority? _authority;
  int _routeEpoch = 0;
  int _lastElapsedMs = 0;

  @override
  Future<KioskPeripheralRuntimeSnapshot> snapshot() async {
    if (!_isAndroid) return _unavailable();
    try {
      final raw = await _channel.invokeMethod<Object?>('capabilities');
      if (raw is! Map ||
          raw.length != 3 ||
          raw['schemaVersion'] != 1 ||
          raw['gmsAvailable'] is! bool ||
          raw['inventory'] is! Map) {
        throw const FormatException('invalid peripheral capabilities');
      }
      final gmsAvailable = raw['gmsAvailable'] as bool;
      final inventoryRaw = raw['inventory'];
      final inventory = KioskPeripheralInventory.fromChannel(
        inventoryRaw,
        gmsAvailable: gmsAvailable,
      );
      if (_routeEpoch >= 0x7ffffffe) {
        throw StateError('peripheral_route_epoch_exhausted');
      }
      final authority = KioskPeripheralAuthority(
        deviceRevision: inventory.inventoryRevision,
        policyRevision: inventory.inventoryRevision,
        sessionEpoch: 1,
        routeEpoch: ++_routeEpoch,
        lifecycleEpoch: 1,
      );
      _authority = authority;
      return KioskPeripheralRuntimeSnapshot(
        rawInventory: inventoryRaw,
        authority: authority,
        gmsAvailable: gmsAvailable,
      );
    } catch (_) {
      _authority = null;
      return _unavailable();
    }
  }

  @override
  Future<Object?> takeNextInput(String providerId) async {
    final authority = _authority;
    if (!_isAndroid ||
        authority == null ||
        !RegExp(r'^[a-z][a-z0-9_.-]{2,63}$').hasMatch(providerId)) {
      return null;
    }
    final raw = await _channel
        .invokeMethod<Object?>('takeNextInput', {
          'providerId': providerId,
          'deviceRevision': authority.deviceRevision,
          'policyRevision': authority.policyRevision,
          'sessionEpoch': authority.sessionEpoch,
          'routeEpoch': authority.routeEpoch,
          'lifecycleEpoch': authority.lifecycleEpoch,
        })
        .timeout(const Duration(seconds: 16));
    if (raw is! Map ||
        raw.length != 2 ||
        raw['input'] is! Map ||
        raw['nowElapsedMs'] is! int ||
        (raw['nowElapsedMs'] as int) < 0) {
      throw const FormatException('invalid peripheral input response');
    }
    _lastElapsedMs = raw['nowElapsedMs'] as int;
    return raw['input'];
  }

  @override
  int nowElapsedMs() => _lastElapsedMs;

  @override
  Future<bool> requestProviderPermission(String providerId) async {
    if (!_isAndroid || providerId != 'ble.gatt' || _authority == null) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('requestPermission', {
            'providerId': providerId,
          }) ==
          true;
    } catch (_) {
      return false;
    }
  }
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
