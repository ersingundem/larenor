import 'package:flutter/foundation.dart';

@immutable
final class KioskRemoteDevice {
  const KioskRemoteDevice({
    required this.id,
    required this.revision,
    required this.name,
    required this.state,
  });
  final String id, name, state;
  final int revision;
}

@immutable
final class KioskRemotePairing {
  const KioskRemotePairing({
    required this.id,
    required this.deviceId,
    required this.revision,
    required this.name,
    required this.scopes,
    required this.state,
    required this.expiresAtMs,
    required this.mqttClientId,
    required this.mqttTopicPrefix,
  });
  final String id, deviceId, name, state, mqttClientId, mqttTopicPrefix;
  final int revision, expiresAtMs;
  final List<String> scopes;
}

@immutable
final class KioskRemoteSnapshot {
  const KioskRemoteSnapshot({required this.devices, required this.pairings});
  final List<KioskRemoteDevice> devices;
  final List<KioskRemotePairing> pairings;
}

@immutable
final class KioskRemoteCreated {
  const KioskRemoteCreated({required this.pairing, required this.token});
  final KioskRemotePairing pairing;
  final String token;
}
