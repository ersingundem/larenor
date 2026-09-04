import 'dart:convert';

import '../../../shared/network/server_bound_client.dart';

/// A commissioned Home Assistant bridge, not a claim that arbitrary intercom
/// wires can be connected to a relay. No GPIO, voltage or bus commands live here.
class DoorStation {
  const DoorStation({
    required this.id,
    required this.name,
    required this.serverUrl,
    this.cameraEntityId,
    this.chimeEntityId,
    this.callActiveEntityId,
    this.doorContactEntityId,
    this.unlockEntityId,
    this.requiresActiveCall = true,
    this.unlockEnabled = false,
  });

  final String id;
  final String name;
  final String serverUrl;
  final String? cameraEntityId;
  final String? chimeEntityId;
  final String? callActiveEntityId;
  final String? doorContactEntityId;
  final String? unlockEntityId;
  final bool requiresActiveCall;
  final bool unlockEnabled;

  static const storageKey = 'door_stations_v1';
  static const maxStations = 16;
  static const maxEncodedBytes = 64 * 1024;

  /// Shared by preferences and backup validation; errors never include data.
  static List<DoorStation> decodeStored(Object? raw) {
    if (raw is! String || utf8.encode(raw).length > maxEncodedBytes) {
      throw const FormatException('Invalid station configuration.');
    }
    try {
      return decodeList(jsonDecode(raw));
    } catch (_) {
      throw const FormatException('Invalid station configuration.');
    }
  }

  static String encodeStored(List<DoorStation> stations) {
    final raw = jsonEncode(
      stations.map((station) => station.toJson()).toList(),
    );
    decodeStored(raw);
    return raw;
  }

  /// Imported mappings require local commissioning before physical control.
  static String uncommissionStored(String raw) => encodeStored(
    decodeStored(raw)
        .map(
          (station) => DoorStation.fromJson({
            ...station.toJson(),
            'unlockEnabled': false,
          }),
        )
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'serverUrl': serverUrl,
    'cameraEntityId': cameraEntityId,
    'chimeEntityId': chimeEntityId,
    'callActiveEntityId': callActiveEntityId,
    'doorContactEntityId': doorContactEntityId,
    'unlockEntityId': unlockEntityId,
    'requiresActiveCall': requiresActiveCall,
    'unlockEnabled': unlockEnabled,
  };

  factory DoorStation.fromJson(Map<String, dynamic> json) {
    const keys = {
      'id',
      'name',
      'serverUrl',
      'cameraEntityId',
      'chimeEntityId',
      'callActiveEntityId',
      'doorContactEntityId',
      'unlockEntityId',
      'requiresActiveCall',
      'unlockEnabled',
    };
    if (!keys.containsAll(json.keys)) {
      throw const FormatException('Invalid station fields.');
    }
    String requiredText(String key, int max) {
      final value = json[key];
      if (value is! String ||
          value.trim().isEmpty ||
          value.length > max ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException('Invalid station field.');
      }
      return value;
    }

    final id = requiredText('id', 100);
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('Invalid station ID.');
    }
    final server = requiredText('serverUrl', 2048);
    if (server != server.trim()) {
      throw const FormatException('Invalid station server.');
    }
    // Uri parsing normalizes literal/once-encoded dot segments; reject these
    // in the source too, before the shared decoded-path validator sees them.
    if (server.split('/').any((part) {
      return RegExp(r'^(?:\.|%2e){1,2}$', caseSensitive: false).hasMatch(part);
    })) {
      throw const FormatException('Invalid station server.');
    }
    parseServerUrl(server);
    String? entity(String key, Set<String> domains) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String ||
          value.length > 255 ||
          !RegExp(r'^[a-z_]+\.[a-z0-9_]+$').hasMatch(value) ||
          !domains.contains(value.split('.').first)) {
        throw const FormatException('Invalid station entity.');
      }
      return value;
    }

    bool flag(String key, bool fallback) {
      final value = json[key];
      if (!json.containsKey(key)) return fallback;
      if (value is! bool) {
        throw const FormatException('Invalid station option.');
      }
      return value;
    }

    final station = DoorStation(
      id: id,
      name: requiredText('name', 80),
      serverUrl: server,
      cameraEntityId: entity('cameraEntityId', {'camera'}),
      chimeEntityId: entity('chimeEntityId', {'binary_sensor'}),
      callActiveEntityId: entity('callActiveEntityId', {'binary_sensor'}),
      doorContactEntityId: entity('doorContactEntityId', {'binary_sensor'}),
      // Persistent switches are deliberately not accepted as door release.
      // The hardware bridge must expose a bounded pulse or a real lock action.
      unlockEntityId: entity('unlockEntityId', {'button', 'lock'}),
      requiresActiveCall: flag('requiresActiveCall', true),
      unlockEnabled: flag('unlockEnabled', false),
    );
    if (station.unlockEnabled &&
        (station.unlockEntityId == null ||
            (station.requiresActiveCall &&
                station.callActiveEntityId == null))) {
      throw const FormatException('Door release requires a configured bridge.');
    }
    return station;
  }

  @override
  bool operator ==(Object other) =>
      other is DoorStation &&
      id == other.id &&
      name == other.name &&
      serverUrl == other.serverUrl &&
      cameraEntityId == other.cameraEntityId &&
      chimeEntityId == other.chimeEntityId &&
      callActiveEntityId == other.callActiveEntityId &&
      doorContactEntityId == other.doorContactEntityId &&
      unlockEntityId == other.unlockEntityId &&
      requiresActiveCall == other.requiresActiveCall &&
      unlockEnabled == other.unlockEnabled;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    serverUrl,
    cameraEntityId,
    chimeEntityId,
    callActiveEntityId,
    doorContactEntityId,
    unlockEntityId,
    requiresActiveCall,
    unlockEnabled,
  );

  static List<DoorStation> decodeList(Object? value) {
    if (value is! List || value.length > maxStations) {
      throw const FormatException('Invalid stations.');
    }
    final stations = value.map((value) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid station.');
      }
      return DoorStation.fromJson(value);
    }).toList();
    if (stations.map((s) => s.id).toSet().length != stations.length) {
      throw const FormatException('Duplicate station.');
    }
    return List.unmodifiable(stations);
  }
}
