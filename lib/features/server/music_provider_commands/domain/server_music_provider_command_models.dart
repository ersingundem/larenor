import '../../domain/server_models.dart';
import '../../media_preparations/domain/server_media_preparation_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

String _choice(Object? value, Set<String> choices) {
  if (value is! String || !choices.contains(value)) _invalid();
  return value;
}

String _digest(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

DateTime _time(Object? value) {
  if (value is! String || value.length != 24) _invalid();
  final parsed = DateTime.tryParse(value);
  if (parsed == null || parsed.toIso8601String() != value) _invalid();
  return parsed;
}

abstract final class _ProviderCommandFields {
  static const domains = {'spotify', 'apple_music', 'ytmusic'};
  static const commands = {'enable', 'disable'};
  static Map<String, dynamic> exact(Object? value, Set<String> keys) =>
      mediaObject(value, keys);
  static void unavailable(Map<String, dynamic> json) {
    if (json['effectAvailable'] != false || json['installAvailable'] != false) {
      _invalid();
    }
  }
}

class ServerMusicProviderCommandPreview {
  ServerMusicProviderCommandPreview._(Map<String, dynamic> json)
    : id = mediaId(json['id']),
      revision = mediaInteger(json['revision'], max: 1),
      installationId = mediaId(json['installationId']),
      installationRevision = mediaInteger(json['installationRevision']),
      providerSetupId = mediaId(json['providerSetupId']),
      providerRevision = mediaInteger(json['providerRevision']),
      providerDomain = _choice(
        json['providerDomain'],
        _ProviderCommandFields.domains,
      ),
      command = _choice(json['command'], _ProviderCommandFields.commands),
      planHash = _digest(json['planHash']),
      createdAt = _time(json['createdAt']),
      expiresAt = _time(json['expiresAt']),
      effectAvailable = json['effectAvailable'] as bool,
      installAvailable = json['installAvailable'] as bool {
    _ProviderCommandFields.unavailable(json);
    final settings = json['settings'];
    final blockers = json['blockers'];
    if (revision != 1 ||
        settings is! Map ||
        settings.isNotEmpty ||
        blockers is! List ||
        blockers.length != 1 ||
        blockers.single != 'effect_unavailable' ||
        !expiresAt.isAfter(createdAt)) {
      _invalid();
    }
  }
  factory ServerMusicProviderCommandPreview.fromJson(Object? value) =>
      ServerMusicProviderCommandPreview._(
        _ProviderCommandFields.exact(value, {
          'id',
          'revision',
          'installationId',
          'installationRevision',
          'providerSetupId',
          'providerRevision',
          'providerDomain',
          'command',
          'settings',
          'planHash',
          'effectAvailable',
          'installAvailable',
          'blockers',
          'createdAt',
          'expiresAt',
        }),
      );
  final String id,
      installationId,
      providerSetupId,
      providerDomain,
      command,
      planHash;
  final int revision, installationRevision, providerRevision;
  final DateTime createdAt, expiresAt;
  final bool effectAvailable, installAvailable;
}

class ServerMusicProviderCommand {
  ServerMusicProviderCommand._(Map<String, dynamic> json)
    : id = mediaId(json['id']),
      revision = mediaInteger(json['revision'], max: 1),
      requestId = mediaId(json['requestId']),
      previewId = mediaId(json['previewId']),
      installationId = mediaId(json['installationId']),
      installationRevision = mediaInteger(json['installationRevision']),
      providerSetupId = mediaId(json['providerSetupId']),
      providerRevision = mediaInteger(json['providerRevision']),
      providerDomain = _choice(
        json['providerDomain'],
        _ProviderCommandFields.domains,
      ),
      command = _choice(json['command'], _ProviderCommandFields.commands),
      state = _choice(json['state'], {'blocked'}),
      errorCode = _choice(json['errorCode'], {'effect_unavailable'}),
      effectAvailable = json['effectAvailable'] as bool,
      installAvailable = json['installAvailable'] as bool,
      createdAt = _time(json['createdAt']) {
    _ProviderCommandFields.unavailable(json);
    if (revision != 1) _invalid();
  }
  factory ServerMusicProviderCommand.fromJson(Object? value) =>
      ServerMusicProviderCommand._(
        _ProviderCommandFields.exact(value, {
          'id',
          'revision',
          'requestId',
          'previewId',
          'installationId',
          'installationRevision',
          'providerSetupId',
          'providerRevision',
          'providerDomain',
          'command',
          'state',
          'errorCode',
          'effectAvailable',
          'installAvailable',
          'createdAt',
        }),
      );
  final String id, requestId, previewId, installationId, providerSetupId;
  final String providerDomain, command, state, errorCode;
  final int revision, installationRevision, providerRevision;
  final bool effectAvailable, installAvailable;
  final DateTime createdAt;
}

class ServerMusicProviderCommandIntent {
  ServerMusicProviderCommandIntent({
    required this.installationId,
    required this.installationRevision,
    required this.providerSetupId,
    required this.providerRevision,
    required this.providerDomain,
    required this.command,
    required this.requestId,
  }) {
    mediaId(installationId);
    mediaId(providerSetupId);
    mediaId(requestId);
    mediaInteger(installationRevision);
    mediaInteger(providerRevision);
    _choice(providerDomain, _ProviderCommandFields.domains);
    _choice(command, _ProviderCommandFields.commands);
  }
  final String installationId,
      providerSetupId,
      providerDomain,
      command,
      requestId;
  final int installationRevision, providerRevision;
  Map<String, Object> toJson() => {
    'requestId': requestId,
    'installationId': installationId,
    'expectedInstallationRevision': installationRevision,
    'providerSetupId': providerSetupId,
    'expectedProviderRevision': providerRevision,
    'providerDomain': providerDomain,
    'command': command,
    'settings': <String, Object>{},
  };
  bool accepts(ServerMusicProviderCommandPreview value) =>
      value.installationId == installationId &&
      value.installationRevision == installationRevision &&
      value.providerSetupId == providerSetupId &&
      value.providerRevision == providerRevision &&
      value.providerDomain == providerDomain &&
      value.command == command;
}
