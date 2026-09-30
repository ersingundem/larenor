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

abstract interface class KioskPeripheralRetirementRuntime {
  Future<void> retire();
}

/// Review-only Android adapter for explicitly armed NFC and external HID input.
final class AndroidKioskPeripheralRuntime
    implements
        KioskPeripheralRuntime,
        KioskPeripheralPermissionRuntime,
        KioskPeripheralRetirementRuntime {
  AndroidKioskPeripheralRuntime({
    MethodChannel? channel,
    bool? isAndroid,
    Duration? retirementTimeout,
  }) : _retirementTimeout = retirementTimeout ?? const Duration(seconds: 2),
       _channel =
           channel ??
           const MethodChannel('com.ersingundem.larenor/kiosk_peripherals'),
       _isAndroid =
           isAndroid ?? defaultTargetPlatform == TargetPlatform.android;

  final MethodChannel _channel;
  final bool _isAndroid;
  final Duration _retirementTimeout;
  KioskPeripheralAuthority? _authority;
  int _routeEpoch = 0;
  int _lastElapsedMs = 0;
  int _retirementEpoch = 0;
  Future<void> _retiring = Future<void>.value();
  bool _retirementUncertain = false;

  @override
  Future<KioskPeripheralRuntimeSnapshot> snapshot() async {
    if (!_isAndroid) return _unavailable();
    final epoch = _retirementEpoch;
    try {
      await _retiring;
      if (epoch != _retirementEpoch || _retirementUncertain) {
        return _unavailable();
      }
      final raw = await _channel.invokeMethod<Object?>('capabilities');
      if (epoch != _retirementEpoch || _retirementUncertain) {
        return _unavailable();
      }
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
      if (epoch == _retirementEpoch) _authority = null;
      return _unavailable();
    }
  }

  @override
  Future<Object?> takeNextInput(String providerId) async {
    final epoch = _retirementEpoch;
    await _retiring;
    if (epoch != _retirementEpoch || _retirementUncertain) return null;
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
    if (epoch != _retirementEpoch || _authority != authority) return null;
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
    final epoch = _retirementEpoch;
    await _retiring;
    if (epoch != _retirementEpoch || _retirementUncertain) return false;
    if (!_isAndroid || providerId != 'ble.gatt' || _authority == null) {
      return false;
    }
    try {
      final allowed = await _channel.invokeMethod<bool>('requestPermission', {
        'providerId': providerId,
      });
      return epoch == _retirementEpoch && _authority != null && allowed == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> retire() {
    _retirementEpoch++;
    _authority = null;
    _lastElapsedMs = 0;
    if (!_isAndroid) return Future<void>.value();
    final operation = _retiring.then((_) async {
      try {
        await _channel.invokeMethod<void>('retire').timeout(_retirementTimeout);
        _retirementUncertain = false;
      } catch (_) {
        // Local authority is already retired. A missing native acknowledgement
        // fences every later native operation until a new explicit retirement
        // is acknowledged or the runtime instance is replaced.
        _retirementUncertain = true;
      }
    });
    _retiring = operation;
    return operation;
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
