import 'dart:convert';

import '../../domain/server_models.dart';

enum ServerServiceKind {
  homeAssistant('home_assistant', 'Home Assistant'),
  jellyfin('jellyfin', 'Jellyfin'),
  seerr('seerr', 'Seerr'),
  sonarr('sonarr', 'Sonarr'),
  radarr('radarr', 'Radarr'),
  lidarr('lidarr', 'Lidarr'),
  readarr('readarr', 'Readarr'),
  bazarr('bazarr', 'Bazarr'),
  prowlarr('prowlarr', 'Prowlarr'),
  qbittorrent('qbittorrent', 'qBittorrent'),
  musicAssistant('music_assistant', 'Music Assistant'),
  proxmox('proxmox', 'Proxmox'),
  keenetic('keenetic', 'Keenetic'),
  frigate('frigate', 'Frigate'),
  immich('immich', 'Immich'),
  adguard('adguard', 'AdGuard Home'),
  esphome('esphome', 'ESPHome');

  const ServerServiceKind(this.wireName, this.label);
  final String wireName, label;
}

enum ServerServiceVerificationState {
  never,
  reachable,
  authenticated,
  unavailable,
  unauthorized,
  unsupported,
}

const serviceCredentialKeys = [
  'token',
  'apiKey',
  'username',
  'password',
  'userId',
];

enum ServerServiceAuthMethod {
  none([]),
  token(['token']),
  apiKey(['apiKey']),
  usernamePassword(['username', 'password']);

  const ServerServiceAuthMethod(this.credentialKeys);
  final List<String> credentialKeys;
}

/// Credential combinations understood by Server's fixed connection probes.
/// Previously stored fields can still be preserved without re-entering them.
List<ServerServiceAuthMethod> serviceAuthMethods(ServerServiceKind kind) =>
    switch (kind) {
      ServerServiceKind.homeAssistant ||
      ServerServiceKind.musicAssistant => const [ServerServiceAuthMethod.token],
      ServerServiceKind.seerr ||
      ServerServiceKind.sonarr ||
      ServerServiceKind.radarr ||
      ServerServiceKind.lidarr ||
      ServerServiceKind.readarr ||
      ServerServiceKind.bazarr ||
      ServerServiceKind.prowlarr => const [ServerServiceAuthMethod.apiKey],
      ServerServiceKind.jellyfin || ServerServiceKind.immich => const [
        ServerServiceAuthMethod.apiKey,
        ServerServiceAuthMethod.token,
      ],
      ServerServiceKind.qbittorrent ||
      ServerServiceKind.adguard ||
      ServerServiceKind.keenetic => const [
        ServerServiceAuthMethod.usernamePassword,
      ],
      ServerServiceKind.proxmox => const [
        ServerServiceAuthMethod.token,
        ServerServiceAuthMethod.usernamePassword,
      ],
      ServerServiceKind.frigate ||
      ServerServiceKind.esphome => const [ServerServiceAuthMethod.none],
    };

bool validServiceCredentialCombination(
  ServerServiceKind kind,
  Map<String, String> credentials,
) =>
    credentials.isEmpty ||
    serviceAuthMethods(kind).any(
      (method) =>
          credentials.length == method.credentialKeys.length &&
          method.credentialKeys.every(credentials.containsKey),
    );

String serviceEndpoint(String value) {
  if (value.length > 2048) {
    throw const LarenorServerException('invalid_request');
  }
  try {
    return ServerEndpoint(value).baseUrl;
  } catch (_) {
    throw const LarenorServerException('invalid_request');
  }
}

bool validServiceName(String value) =>
    value.trim() == value &&
    value.runes.isNotEmpty &&
    value.runes.length <= 80 &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]')) &&
    !value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff);

bool validServiceCredentials(Map<String, String> value) =>
    value.length <= serviceCredentialKeys.length &&
    value.entries.every(
      (entry) =>
          serviceCredentialKeys.contains(entry.key) &&
          entry.value.isNotEmpty &&
          entry.value.runes.length <= 2048 &&
          !entry.value.contains(RegExp(r'[\x00-\x1f\x7f]')) &&
          !entry.value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff),
    ) &&
    value.values.fold<int>(
          0,
          (length, text) => length + utf8.encode(text).length,
        ) <=
        4096;

Never _invalidService() =>
    throw const LarenorServerException('invalid_response');

class ServiceVerification {
  const ServiceVerification._(this.state, this.checkedAt, this.version);
  final ServerServiceVerificationState state;
  final DateTime? checkedAt;
  final String? version;

  factory ServiceVerification.fromJson(Map<String, dynamic> json) {
    if (json.length != 3 ||
        !json.keys.toSet().containsAll({'state', 'checkedAt', 'version'})) {
      _invalidService();
    }
    final state = ServerServiceVerificationState.values
        .where((value) => value.name == json['state'])
        .firstOrNull;
    if (state == null) _invalidService();
    DateTime? date;
    if (json['checkedAt'] != null) {
      final text = serverText(json['checkedAt'], max: 40);
      date = DateTime.tryParse(text);
      if (date == null ||
          !date.isUtc ||
          !RegExp(r'T.*(?:Z|\+00:00)$').hasMatch(text)) {
        _invalidService();
      }
    }
    if ((state == ServerServiceVerificationState.never) != (date == null)) {
      _invalidService();
    }
    final version = json['version'] == null
        ? null
        : serverText(json['version'], max: 80);
    if ((state == ServerServiceVerificationState.never && version != null) ||
        (version != null &&
            !RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._+:/()\-]{0,79}$')
                .hasMatch(version))) {
      _invalidService();
    }
    return ServiceVerification._(state, date, version);
  }

  @override
  String toString() => 'ServiceVerification';
}

class ServerService {
  const ServerService._({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    required this.revision,
    required this.credentialKeys,
    required this.verification,
  });
  final String id, name, baseUrl;
  final ServerServiceKind kind;
  final int revision;
  final List<String> credentialKeys;
  final ServiceVerification verification;

  factory ServerService.fromJson(Map<String, dynamic> json) {
    if (json.length != 7 ||
        !json.keys.toSet().containsAll({
          'id',
          'name',
          'kind',
          'baseUrl',
          'revision',
          'credentialKeys',
          'verification',
        })) {
      _invalidService();
    }
    final id = serverText(json['id'], max: 32);
    final name = serverText(json['name'], max: 160);
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) || !validServiceName(name)) {
      _invalidService();
    }
    final kind = ServerServiceKind.values
        .where((value) => value.wireName == json['kind'])
        .firstOrNull;
    final revision = json['revision'];
    final keys = json['credentialKeys'];
    if (kind == null ||
        revision is! int ||
        revision < 1 ||
        revision > 0x7fffffffffffffff ||
        keys is! List ||
        keys.length > serviceCredentialKeys.length ||
        keys.any(
          (key) => key is! String || !serviceCredentialKeys.contains(key),
        ) ||
        keys.toSet().length != keys.length) {
      _invalidService();
    }
    final String url;
    try {
      url = serviceEndpoint(serverText(json['baseUrl'], max: 2048));
    } catch (_) {
      _invalidService();
    }
    return ServerService._(
      id: id,
      name: name,
      kind: kind,
      baseUrl: url,
      revision: revision,
      credentialKeys: List.unmodifiable(keys.cast<String>()),
      verification: ServiceVerification.fromJson(
        serverObject(json['verification']),
      ),
    );
  }

  @override
  String toString() => 'ServerService';
}
