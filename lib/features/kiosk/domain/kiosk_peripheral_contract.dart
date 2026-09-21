import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

final _providerId = RegExp(r'^[a-z][a-z0-9_.-]{2,63}$');
final _eventId = RegExp(r'^[0-9a-f]{32}$');
const _maxRevision = 0x7fffffff;
const _inputKinds = {
  KioskPeripheralKind.qr,
  KioskPeripheralKind.nfc,
  KioskPeripheralKind.ble,
  KioskPeripheralKind.usb,
};

enum KioskPeripheralKind { qr, nfc, ble, usb, tts, print }

enum KioskPeripheralPermission { notRequired, granted, denied, unknown }

enum KioskPeripheralAvailability {
  ready,
  disabled,
  unsupported,
  permissionDenied,
  permissionUnknown,
  disconnected,
  gmsUnavailable,
}

enum KioskPeripheralDisposition { reviewOnly }

@immutable
final class KioskPeripheralAuthority {
  const KioskPeripheralAuthority({
    required this.deviceRevision,
    required this.policyRevision,
    required this.sessionEpoch,
    required this.routeEpoch,
    required this.lifecycleEpoch,
  });

  final int deviceRevision;
  final int policyRevision;
  final int sessionEpoch;
  final int routeEpoch;
  final int lifecycleEpoch;

  bool get valid =>
      _revision(deviceRevision) &&
      _revision(policyRevision) &&
      _revision(sessionEpoch) &&
      _revision(routeEpoch) &&
      _revision(lifecycleEpoch);

  @override
  String toString() => 'KioskPeripheralAuthority(redacted)';
}

@immutable
final class KioskPeripheralCapability {
  const KioskPeripheralCapability._({
    required this.providerId,
    required this.kind,
    required this.revision,
    required this.supported,
    required this.enabledByUser,
    required this.permission,
    required this.connected,
    required this.requiresGms,
    required this.maxPayloadBytes,
    required this.gmsAvailable,
  });

  final String providerId;
  final KioskPeripheralKind kind;
  final int revision;
  final bool supported;
  final bool enabledByUser;
  final KioskPeripheralPermission permission;
  final bool connected;
  final bool requiresGms;
  final int maxPayloadBytes;
  final bool gmsAvailable;

  KioskPeripheralAvailability get availability {
    if (!supported) return KioskPeripheralAvailability.unsupported;
    if (!enabledByUser) return KioskPeripheralAvailability.disabled;
    if (permission == KioskPeripheralPermission.denied) {
      return KioskPeripheralAvailability.permissionDenied;
    }
    if (permission == KioskPeripheralPermission.unknown) {
      return KioskPeripheralAvailability.permissionUnknown;
    }
    if (requiresGms && !gmsAvailable) {
      return KioskPeripheralAvailability.gmsUnavailable;
    }
    if (!connected) return KioskPeripheralAvailability.disconnected;
    return KioskPeripheralAvailability.ready;
  }

  bool get acceptsInput =>
      _inputKinds.contains(kind) &&
      availability == KioskPeripheralAvailability.ready;

  Map<String, Object?> toPublicJson() => {
    'providerId': providerId,
    'kind': kind.name,
    'revision': revision,
    'availability': availability.name,
    'enabledByUser': enabledByUser,
    'maxPayloadBytes': maxPayloadBytes,
  };

  @override
  String toString() => 'KioskPeripheralCapability($providerId, ${kind.name})';
}

@immutable
final class KioskPeripheralInventory {
  const KioskPeripheralInventory._({
    required this.inventoryRevision,
    required this.providers,
  });

  final int inventoryRevision;
  final List<KioskPeripheralCapability> providers;

  factory KioskPeripheralInventory.fromChannel(
    Object? raw, {
    required bool gmsAvailable,
  }) {
    final map = _strictMap(raw, const {
      'schemaVersion',
      'inventoryRevision',
      'providers',
    });
    if (map['schemaVersion'] != 1 || !_revision(map['inventoryRevision'])) {
      _invalid();
    }
    final rawProviders = map['providers'];
    if (rawProviders is! List ||
        rawProviders.isEmpty ||
        rawProviders.length > 24) {
      _invalid();
    }
    final providers = <KioskPeripheralCapability>[];
    final providerIds = <String>{};
    final kinds = <KioskPeripheralKind>{};
    for (final rawProvider in rawProviders) {
      final value = _strictMap(rawProvider, const {
        'providerId',
        'kind',
        'revision',
        'supported',
        'enabledByUser',
        'permission',
        'connected',
        'requiresGms',
        'maxPayloadBytes',
      });
      final id = value['providerId'];
      final kind = _enumValue(KioskPeripheralKind.values, value['kind']);
      final permission = _enumValue(
        KioskPeripheralPermission.values,
        value['permission'],
      );
      final revision = value['revision'];
      final supported = value['supported'];
      final enabled = value['enabledByUser'];
      final connected = value['connected'];
      final requiresGms = value['requiresGms'];
      final maxPayload = value['maxPayloadBytes'];
      if (id is! String ||
          !_providerId.hasMatch(id) ||
          !providerIds.add(id) ||
          kind == null ||
          permission == null ||
          !_revision(revision) ||
          supported is! bool ||
          enabled is! bool ||
          connected is! bool ||
          requiresGms is! bool ||
          maxPayload is! int ||
          (_inputKinds.contains(kind)
              ? maxPayload < 1 || maxPayload > 4096
              : maxPayload != 0)) {
        _invalid();
      }
      kinds.add(kind);
      providers.add(
        KioskPeripheralCapability._(
          providerId: id,
          kind: kind,
          revision: revision as int,
          supported: supported,
          enabledByUser: enabled,
          permission: permission,
          connected: connected,
          requiresGms: requiresGms,
          maxPayloadBytes: maxPayload,
          gmsAvailable: gmsAvailable,
        ),
      );
    }
    if (!kinds.containsAll(KioskPeripheralKind.values)) _invalid();
    return KioskPeripheralInventory._(
      inventoryRevision: map['inventoryRevision']! as int,
      providers: List.unmodifiable(providers),
    );
  }

  KioskPeripheralCapability provider(String providerId) =>
      providers.singleWhere(
        (candidate) => candidate.providerId == providerId,
        orElse: _invalid,
      );

  Map<String, Object?> toPublicJson() => {
    'schemaVersion': 1,
    'inventoryRevision': inventoryRevision,
    'providers': providers.map((provider) => provider.toPublicJson()).toList(),
  };
}

@immutable
final class KioskPeripheralInput {
  const KioskPeripheralInput._({
    required this.eventId,
    required this.providerId,
    required this.kind,
    required this.capabilityRevision,
    required this.sequence,
    required this.capturedAtElapsedMs,
    required this.payload,
  });

  final String eventId;
  final String providerId;
  final KioskPeripheralKind kind;
  final int capabilityRevision;
  final int sequence;
  final int capturedAtElapsedMs;
  final String payload;

  KioskPeripheralDisposition get disposition =>
      KioskPeripheralDisposition.reviewOnly;
  bool get canExecuteCommand => false;
  bool get canInjectJavaScript => false;

  Map<String, Object?> toAuditJson() => {
    'schemaVersion': 1,
    'eventId': eventId,
    'providerId': providerId,
    'kind': kind.name,
    'capabilityRevision': capabilityRevision,
    'sequence': sequence,
    'capturedAtElapsedMs': capturedAtElapsedMs,
    'payloadBytes': utf8.encode(payload).length,
    'disposition': disposition.name,
  };

  @override
  String toString() => 'KioskPeripheralInput(redacted)';
}

final class KioskPeripheralInputGate {
  KioskPeripheralInputGate({
    this.maxAge = const Duration(seconds: 15),
    this.replayWindow = 256,
  }) {
    if (maxAge <= Duration.zero ||
        maxAge > const Duration(minutes: 1) ||
        replayWindow < 16 ||
        replayWindow > 1024) {
      throw ArgumentError('invalid peripheral gate bounds');
    }
  }

  final Duration maxAge;
  final int replayWindow;
  final Set<String> _seen = {};
  final Queue<String> _seenOrder = Queue();
  final Map<String, int> _lastSequence = {};

  KioskPeripheralInput accept(
    Object? raw, {
    required KioskPeripheralInventory inventory,
    required KioskPeripheralAuthority expectedAuthority,
    required bool Function() isCurrent,
    required int nowElapsedMs,
  }) {
    final map = _strictMap(raw, const {
      'schemaVersion',
      'eventId',
      'providerId',
      'kind',
      'capabilityRevision',
      'deviceRevision',
      'policyRevision',
      'sessionEpoch',
      'routeEpoch',
      'lifecycleEpoch',
      'sequence',
      'capturedAtElapsedMs',
      'payload',
    });
    if (!expectedAuthority.valid || map['schemaVersion'] != 1) _invalid();
    try {
      if (!isCurrent()) _invalid();
    } catch (_) {
      _invalid();
    }
    final id = map['eventId'];
    final providerId = map['providerId'];
    final kind = _enumValue(KioskPeripheralKind.values, map['kind']);
    final revision = map['capabilityRevision'];
    final sequence = map['sequence'];
    final capturedAt = map['capturedAtElapsedMs'];
    final payload = map['payload'];
    if (id is! String ||
        !_eventId.hasMatch(id) ||
        _seen.contains(id) ||
        providerId is! String ||
        kind == null ||
        !_inputKinds.contains(kind) ||
        !_revision(revision) ||
        sequence is! int ||
        !_revision(sequence) ||
        capturedAt is! int ||
        capturedAt < 0 ||
        nowElapsedMs < capturedAt ||
        nowElapsedMs - capturedAt > maxAge.inMilliseconds ||
        payload is! String ||
        payload.isEmpty ||
        payload.contains('\u0000') ||
        !_authorityMatches(map, expectedAuthority)) {
      _invalid();
    }
    final capability = inventory.provider(providerId);
    if (capability.kind != kind ||
        capability.revision != revision ||
        !capability.acceptsInput ||
        utf8.encode(payload).length > capability.maxPayloadBytes ||
        sequence <= (_lastSequence[providerId] ?? 0)) {
      _invalid();
    }
    _seen.add(id);
    _seenOrder.addLast(id);
    if (_seenOrder.length > replayWindow) {
      _seen.remove(_seenOrder.removeFirst());
    }
    _lastSequence[providerId] = sequence;
    return KioskPeripheralInput._(
      eventId: id,
      providerId: providerId,
      kind: kind,
      capabilityRevision: revision as int,
      sequence: sequence,
      capturedAtElapsedMs: capturedAt,
      payload: payload,
    );
  }
}

bool _authorityMatches(
  Map<String, Object?> map,
  KioskPeripheralAuthority expected,
) =>
    map['deviceRevision'] == expected.deviceRevision &&
    map['policyRevision'] == expected.policyRevision &&
    map['sessionEpoch'] == expected.sessionEpoch &&
    map['routeEpoch'] == expected.routeEpoch &&
    map['lifecycleEpoch'] == expected.lifecycleEpoch;

Map<String, Object?> _strictMap(Object? raw, Set<String> keys) {
  if (raw is! Map || raw.length != keys.length) _invalid();
  final result = <String, Object?>{};
  for (final entry in raw.entries) {
    if (entry.key is! String || !keys.contains(entry.key)) _invalid();
    result[entry.key! as String] = entry.value;
  }
  return result;
}

T? _enumValue<T extends Enum>(List<T> values, Object? name) => name is String
    ? values.where((value) => value.name == name).firstOrNull
    : null;

bool _revision(Object? value) =>
    value is int && value > 0 && value <= _maxRevision;

Never _invalid() => throw const FormatException('peripheral_input_invalid');
