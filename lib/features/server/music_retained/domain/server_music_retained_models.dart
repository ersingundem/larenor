import '../../domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

String _one(Object? value, Set<String> choices) {
  if (value is! String || !choices.contains(value)) _invalid();
  return value;
}

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 0x7fffffffffffffff) _invalid();
  return value;
}

class ServerMusicServiceRevision {
  ServerMusicServiceRevision._(this.serviceId, this.serviceRevision);
  factory ServerMusicServiceRevision.fromJson(Object? value) {
    final map = _object(value, {'serviceId', 'serviceRevision'});
    return ServerMusicServiceRevision._(
      _id(map['serviceId']),
      _revision(map['serviceRevision']),
    );
  }
  final String serviceId;
  final int serviceRevision;
}

class ServerMusicBootstrapReceipt {
  ServerMusicBootstrapReceipt._(
    this.revision,
    this.state,
    this.serverVersion,
    this.schemaVersion,
    this.homeAssistant,
    this.jellyfin,
  );
  factory ServerMusicBootstrapReceipt.fromJson(Object? value) {
    final map = _object(value, {
      'revision',
      'state',
      'serverVersion',
      'schemaVersion',
      'homeAssistant',
      'jellyfin',
    });
    final version = map['serverVersion'];
    final schema = map['schemaVersion'];
    if (version is! String ||
        version.isEmpty ||
        version.length > 80 ||
        schema is! int ||
        schema < 1 ||
        schema > 0x7fffffff) {
      _invalid();
    }
    return ServerMusicBootstrapReceipt._(
      _revision(map['revision']),
      _one(map['state'], {'ready', 'failed'}),
      version,
      schema,
      ServerMusicServiceRevision.fromJson(map['homeAssistant']),
      ServerMusicServiceRevision.fromJson(map['jellyfin']),
    );
  }
  final int revision, schemaVersion;
  final String state, serverVersion;
  final ServerMusicServiceRevision homeAssistant, jellyfin;
}

class ServerMusicProviderStatus {
  ServerMusicProviderStatus._(
    this.id,
    this.domain,
    this.revision,
    this.state,
    this.updatedAt,
  );
  factory ServerMusicProviderStatus.fromJson(Object? value) {
    final map = _object(value, {
      'id',
      'providerDomain',
      'revision',
      'state',
      'updatedAt',
    });
    final rawTime = map['updatedAt'];
    final updated = rawTime is String ? DateTime.tryParse(rawTime) : null;
    if (updated == null || updated.toIso8601String() != rawTime) _invalid();
    return ServerMusicProviderStatus._(
      _id(map['id']),
      _one(map['providerDomain'], {'spotify', 'apple_music', 'ytmusic'}),
      _revision(map['revision']),
      _one(map['state'], {
        'queued',
        'action_required',
        'ready',
        'cancelled',
        'needs_attention',
      }),
      updated,
    );
  }
  final String id, domain, state;
  final int revision;
  final DateTime updatedAt;
}

class ServerMusicRetainedInstallation {
  ServerMusicRetainedInstallation._(
    this.installationId,
    this.installationRevision,
    this.installationState,
    this.state,
    this.errorCode,
    this.bootstrap,
    this.providers,
  );
  factory ServerMusicRetainedInstallation.fromJson(Object? value) {
    final map = _object(value, {
      'installationId',
      'installationRevision',
      'installationState',
      'state',
      'errorCode',
      'bootstrapReceipt',
      'providers',
    });
    final values = map['providers'];
    if (values is! List || values.length > 256) _invalid();
    final providers = values
        .map(ServerMusicProviderStatus.fromJson)
        .toList(growable: false);
    if (providers.map((item) => item.id).toSet().length != providers.length) {
      _invalid();
    }
    final state = _one(map['state'], {'partial', 'failed', 'ready'});
    final error = map['errorCode'];
    if (error != null &&
        !{
          'installation_pending',
          'installation_failed',
          'bootstrap_unknown',
          'installation_changed',
          'dependency_changed',
          'provider_not_ready',
          'provider_failed',
        }.contains(error)) {
      _invalid();
    }
    final receipt = map['bootstrapReceipt'] == null
        ? null
        : ServerMusicBootstrapReceipt.fromJson(map['bootstrapReceipt']);
    if ((state == 'ready') !=
            (error == null &&
                receipt?.state == 'ready' &&
                providers.any((item) => item.state == 'ready')) ||
        (state == 'failed') !=
            {
              'installation_failed',
              'installation_changed',
              'dependency_changed',
              'provider_failed',
            }.contains(error) ||
        (receipt == null) !=
            {
              'installation_pending',
              'installation_failed',
              'bootstrap_unknown',
            }.contains(error)) {
      _invalid();
    }
    return ServerMusicRetainedInstallation._(
      _id(map['installationId']),
      _revision(map['installationRevision']),
      _one(map['installationState'], {
        'queued',
        'running',
        'container_started',
        'needs_attention',
        'failed',
        'cancelled',
      }),
      state,
      error as String?,
      receipt,
      List.unmodifiable(providers),
    );
  }
  final String installationId, installationState, state;
  final int installationRevision;
  final String? errorCode;
  final ServerMusicBootstrapReceipt? bootstrap;
  final List<ServerMusicProviderStatus> providers;
}

class ServerMusicRetainedOverview {
  ServerMusicRetainedOverview._(this.state, this.installations);
  factory ServerMusicRetainedOverview.fromJson(Object? value) {
    final map = _object(value, {
      'schemaVersion',
      'state',
      'installAvailable',
      'installations',
    });
    final values = map['installations'];
    if (map['schemaVersion'] != 1 ||
        map['installAvailable'] != false ||
        values is! List ||
        values.length > 64) {
      _invalid();
    }
    final installations = values
        .map(ServerMusicRetainedInstallation.fromJson)
        .toList(growable: false);
    if (installations.map((item) => item.installationId).toSet().length !=
        installations.length) {
      _invalid();
    }
    final expected = installations.isEmpty
        ? 'unknown'
        : installations.any((item) => item.state == 'failed')
        ? 'failed'
        : installations.every((item) => item.state == 'ready')
        ? 'ready'
        : 'partial';
    if (map['state'] != expected) _invalid();
    return ServerMusicRetainedOverview._(
      expected,
      List.unmodifiable(installations),
    );
  }
  final String state;
  final List<ServerMusicRetainedInstallation> installations;
  bool get installAvailable => false;
}
