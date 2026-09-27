import 'dart:convert';

import '../../domain/server_models.dart';

Never _invalidResponse() =>
    throw const LarenorServerException('invalid_response');
Never _invalidRequest() =>
    throw const LarenorServerException('invalid_request');

Map<String, dynamic> _exact(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalidResponse();
  }
  return value;
}

String _responseText(
  Object? value, {
  required int min,
  required int max,
  RegExp? pattern,
}) {
  if (value is! String ||
      value.length < min ||
      value.length > max ||
      (pattern != null && !pattern.hasMatch(value))) {
    _invalidResponse();
  }
  return value;
}

String _responseId(Object? value) =>
    _responseText(value, min: 32, max: 32, pattern: RegExp(r'^[0-9a-f]{32}$'));

int _responseRevision(Object? value) {
  if (value is! int || value < 1 || value > 0x7fffffffffffffff) {
    _invalidResponse();
  }
  return value;
}

DateTime _responseTime(Object? value) {
  final text = _responseText(
    value,
    min: 24,
    max: 24,
    pattern: RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'),
  );
  final parsed = DateTime.tryParse(text);
  if (parsed == null || parsed.toIso8601String() != text) _invalidResponse();
  return parsed;
}

T _responseEnum<T extends Enum>(Object? value, Map<String, T> values) {
  if (value is! String || !values.containsKey(value)) _invalidResponse();
  return values[value]!;
}

void _requestId(String value) {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) _invalidRequest();
}

void _requestRevision(int value) {
  if (value < 1 || value > 0x7fffffffffffffff) _invalidRequest();
}

enum ServerMusicProviderDomain { spotify, appleMusic, youtubeMusic }

extension ServerMusicProviderDomainWire on ServerMusicProviderDomain {
  String get wire => switch (this) {
    ServerMusicProviderDomain.spotify => 'spotify',
    ServerMusicProviderDomain.appleMusic => 'apple_music',
    ServerMusicProviderDomain.youtubeMusic => 'ytmusic',
  };
}

const _domains = {
  'spotify': ServerMusicProviderDomain.spotify,
  'apple_music': ServerMusicProviderDomain.appleMusic,
  'ytmusic': ServerMusicProviderDomain.youtubeMusic,
};

enum ServerMusicProviderStage { stable, beta }

const _stages = {
  'stable': ServerMusicProviderStage.stable,
  'beta': ServerMusicProviderStage.beta,
};

enum ServerMusicProviderInteraction {
  oauthAndPlaybackApproval,
  musicKitOrSecureManualToken,
  secureCookieAndPoTokenService,
}

const _providerInteractions = {
  'oauth_and_playback_approval':
      ServerMusicProviderInteraction.oauthAndPlaybackApproval,
  'musickit_or_secure_manual_token':
      ServerMusicProviderInteraction.musicKitOrSecureManualToken,
  'secure_cookie_and_po_token_service':
      ServerMusicProviderInteraction.secureCookieAndPoTokenService,
};

enum ServerMusicProviderSetupFieldType { string, secureString, boolean }

const _fieldTypes = {
  'string': ServerMusicProviderSetupFieldType.string,
  'secure_string': ServerMusicProviderSetupFieldType.secureString,
  'boolean': ServerMusicProviderSetupFieldType.boolean,
};

enum ServerMusicProviderSetupState {
  queued,
  actionRequired,
  ready,
  cancelled,
  needsAttention,
}

const _setupStates = {
  'queued': ServerMusicProviderSetupState.queued,
  'action_required': ServerMusicProviderSetupState.actionRequired,
  'ready': ServerMusicProviderSetupState.ready,
  'cancelled': ServerMusicProviderSetupState.cancelled,
  'needs_attention': ServerMusicProviderSetupState.needsAttention,
};

enum ServerMusicProviderSetupNextAction {
  awaitingCoreDiscovery,
  continueInLarenor,
  retry,
  none,
}

const _nextActions = {
  'awaiting_core_discovery':
      ServerMusicProviderSetupNextAction.awaitingCoreDiscovery,
  'continue_in_larenor': ServerMusicProviderSetupNextAction.continueInLarenor,
  'retry': ServerMusicProviderSetupNextAction.retry,
  'none': ServerMusicProviderSetupNextAction.none,
};

enum ServerMusicProviderSetupInteraction { openExternal, submitForm }

const _setupInteractions = {
  'open_external': ServerMusicProviderSetupInteraction.openExternal,
  'submit_form': ServerMusicProviderSetupInteraction.submitForm,
};

final class ServerMusicProviderCapability {
  ServerMusicProviderCapability._(Map<String, dynamic> json)
    : domain = _responseEnum(json['providerDomain'], _domains),
      name = _responseText(json['name'], min: 1, max: 32),
      stage = _responseEnum(json['stage'], _stages),
      interaction = _responseEnum(json['interaction'], _providerInteractions) {
    if (json['multiInstance'] != true) _invalidResponse();
    final expected = switch (domain) {
      ServerMusicProviderDomain.spotify => (
        'Spotify',
        ServerMusicProviderInteraction.oauthAndPlaybackApproval,
      ),
      ServerMusicProviderDomain.appleMusic => (
        'Apple Music',
        ServerMusicProviderInteraction.musicKitOrSecureManualToken,
      ),
      ServerMusicProviderDomain.youtubeMusic => (
        'YouTube Music',
        ServerMusicProviderInteraction.secureCookieAndPoTokenService,
      ),
    };
    if (name != expected.$1 || interaction != expected.$2) _invalidResponse();
  }

  factory ServerMusicProviderCapability.fromJson(Object? value) =>
      ServerMusicProviderCapability._(
        _exact(value, {
          'providerDomain',
          'name',
          'stage',
          'multiInstance',
          'interaction',
        }),
      );

  final ServerMusicProviderDomain domain;
  final String name;
  final ServerMusicProviderStage stage;
  final ServerMusicProviderInteraction interaction;
  bool get multiInstance => true;
}

final class ServerMusicProviderSetupCapabilities {
  ServerMusicProviderSetupCapabilities._(Map<String, dynamic> json)
    : providers = _providers(json['providers']) {
    if (json['installAvailable'] != false ||
        json['setupEngine'] != 'music_assistant_setup_flow') {
      _invalidResponse();
    }
  }

  factory ServerMusicProviderSetupCapabilities.fromJson(Object? value) =>
      ServerMusicProviderSetupCapabilities._(
        _exact(value, {'installAvailable', 'setupEngine', 'providers'}),
      );

  static List<ServerMusicProviderCapability> _providers(Object? value) {
    if (value is! List || value.length != 3) _invalidResponse();
    final result = value
        .map(ServerMusicProviderCapability.fromJson)
        .toList(growable: false);
    if (result.map((item) => item.domain).toSet().length != 3) {
      _invalidResponse();
    }
    return List.unmodifiable(result);
  }

  final List<ServerMusicProviderCapability> providers;
  bool get installAvailable => false;
  String get setupEngine => 'music_assistant_setup_flow';
}

final class ServerMusicProviderSetupField {
  ServerMusicProviderSetupField._(Map<String, dynamic> json)
    : key = _responseText(
        json['key'],
        min: 1,
        max: 80,
        pattern: RegExp(r'^[a-z][a-z0-9_]{0,79}$'),
      ),
      type = _responseEnum(json['type'], _fieldTypes),
      required = json['required'] as bool;

  factory ServerMusicProviderSetupField.fromJson(Object? value) {
    final json = _exact(value, {'key', 'type', 'required'});
    if (json['required'] is! bool) _invalidResponse();
    return ServerMusicProviderSetupField._(json);
  }

  final String key;
  final ServerMusicProviderSetupFieldType type;
  final bool required;
}

final class ServerMusicProviderSetup {
  ServerMusicProviderSetup._(Map<String, dynamic> json)
    : id = _responseId(json['id']),
      requestId = _responseId(json['requestId']),
      installationId = _responseId(json['installationId']),
      installationRevision = _responseRevision(json['installationRevision']),
      domain = _responseEnum(json['providerDomain'], _domains),
      revision = _responseRevision(json['revision']),
      state = _responseEnum(json['state'], _setupStates),
      nextAction = _responseEnum(json['nextAction'], _nextActions),
      interaction = json['interaction'] == null
          ? null
          : _responseEnum(json['interaction'], _setupInteractions),
      stepId = json['stepId'] == null
          ? null
          : _responseText(
              json['stepId'],
              min: 1,
              max: 80,
              pattern: RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,79}$'),
            ),
      externalUrl = json['externalUrl'] == null
          ? null
          : _externalUrl(json['externalUrl']),
      fields = _fields(json['fields']),
      providerInstanceId = json['providerInstanceId'] == null
          ? null
          : _responseText(
              json['providerInstanceId'],
              min: 1,
              max: 128,
              pattern: RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$'),
            ),
      createdAt = _responseTime(json['createdAt']),
      updatedAt = _responseTime(json['updatedAt']) {
    if (json['installAvailable'] != false ||
        updatedAt.isBefore(createdAt) ||
        !_coherent()) {
      _invalidResponse();
    }
  }

  factory ServerMusicProviderSetup.fromJson(Object? value) =>
      ServerMusicProviderSetup._(
        _exact(value, {
          'id',
          'requestId',
          'installationId',
          'installationRevision',
          'providerDomain',
          'revision',
          'state',
          'nextAction',
          'interaction',
          'stepId',
          'externalUrl',
          'fields',
          'providerInstanceId',
          'installAvailable',
          'createdAt',
          'updatedAt',
        }),
      );

  static List<ServerMusicProviderSetupField> _fields(Object? value) {
    if (value is! List || value.length > 16) _invalidResponse();
    final result = value
        .map(ServerMusicProviderSetupField.fromJson)
        .toList(growable: false);
    if (result.map((item) => item.key).toSet().length != result.length) {
      _invalidResponse();
    }
    return List.unmodifiable(result);
  }

  static Uri _externalUrl(Object? value) {
    final text = _responseText(value, min: 1, max: 4096);
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      _invalidResponse();
    }
    return uri;
  }

  bool _coherent() {
    if ((state == ServerMusicProviderSetupState.ready) !=
        (providerInstanceId != null)) {
      return false;
    }
    final actionRequired =
        state == ServerMusicProviderSetupState.actionRequired;
    if (!actionRequired &&
        (interaction != null ||
            stepId != null ||
            externalUrl != null ||
            fields.isNotEmpty)) {
      return false;
    }
    if (actionRequired) {
      switch (interaction) {
        case ServerMusicProviderSetupInteraction.openExternal:
          if (stepId != null || externalUrl == null || fields.isNotEmpty) {
            return false;
          }
        case ServerMusicProviderSetupInteraction.submitForm:
          if (stepId == null || externalUrl != null || fields.isEmpty) {
            return false;
          }
        case null:
          return false;
      }
    }
    return switch (nextAction) {
      ServerMusicProviderSetupNextAction.awaitingCoreDiscovery =>
        state == ServerMusicProviderSetupState.queued && interaction == null,
      ServerMusicProviderSetupNextAction.continueInLarenor =>
        state == ServerMusicProviderSetupState.actionRequired &&
            interaction != null,
      ServerMusicProviderSetupNextAction.retry =>
        state == ServerMusicProviderSetupState.needsAttention,
      ServerMusicProviderSetupNextAction.none =>
        (state == ServerMusicProviderSetupState.ready ||
                state == ServerMusicProviderSetupState.cancelled) &&
            interaction == null,
    };
  }

  final String id, requestId, installationId;
  final int installationRevision, revision;
  final ServerMusicProviderDomain domain;
  final ServerMusicProviderSetupState state;
  final ServerMusicProviderSetupNextAction nextAction;
  final ServerMusicProviderSetupInteraction? interaction;
  final String? stepId;
  final Uri? externalUrl;
  final List<ServerMusicProviderSetupField> fields;
  final String? providerInstanceId;
  final DateTime createdAt, updatedAt;
  bool get installAvailable => false;

  bool sameIdentity(ServerMusicProviderSetup other) =>
      id == other.id &&
      requestId == other.requestId &&
      installationId == other.installationId &&
      installationRevision == other.installationRevision &&
      domain == other.domain &&
      createdAt == other.createdAt;
}

final class ServerMusicProviderSetupIntent {
  ServerMusicProviderSetupIntent({
    required this.requestId,
    required this.installationId,
    required this.installationRevision,
    required this.domain,
  }) {
    _requestId(requestId);
    _requestId(installationId);
    _requestRevision(installationRevision);
  }

  final String requestId, installationId;
  final int installationRevision;
  final ServerMusicProviderDomain domain;

  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'installationId': installationId,
    'expectedInstallationRevision': installationRevision,
    'providerDomain': domain.wire,
  };

  bool accepts(ServerMusicProviderSetup value) =>
      value.requestId == requestId &&
      value.installationId == installationId &&
      value.installationRevision == installationRevision &&
      value.domain == domain;
}

/// Owns a defensive copy of form values and never renders them in diagnostics.
///
/// The request encoder is intentionally the only way to read the copy. A
/// secure-string remains sensitive even after the server has consumed it.
final class ServerMusicProviderSetupSubmission {
  ServerMusicProviderSetupSubmission(Map<String, Object> values)
    : _values = Map.unmodifiable(Map<String, Object>.from(values)) {
    if (_values.length > 16) _invalidRequest();
    var encodedBytes = 0;
    for (final entry in _values.entries) {
      if (!RegExp(r'^[a-z][a-z0-9_]{0,79}$').hasMatch(entry.key)) {
        _invalidRequest();
      }
      final value = entry.value;
      if (value is String) {
        final bytes = utf8.encode(value).length;
        if (value.isEmpty ||
            value.length > 8192 ||
            bytes > 8192 ||
            value.runes.any((char) => char < 9 || char == 127)) {
          _invalidRequest();
        }
        encodedBytes += bytes;
      } else if (value is! bool) {
        _invalidRequest();
      }
    }
    if (encodedBytes > 32768) _invalidRequest();
  }

  final Map<String, Object> _values;

  void validateAgainst(List<ServerMusicProviderSetupField> fields) {
    final descriptors = {for (final field in fields) field.key: field};
    if (_values.keys.any((key) => !descriptors.containsKey(key)) ||
        fields.any(
          (field) => field.required && !_values.containsKey(field.key),
        )) {
      _invalidRequest();
    }
    for (final entry in _values.entries) {
      final field = descriptors[entry.key]!;
      if ((field.type == ServerMusicProviderSetupFieldType.boolean) !=
          (entry.value is bool)) {
        _invalidRequest();
      }
    }
  }

  Map<String, dynamic> encodeForRequest() => Map<String, dynamic>.from(_values);

  @override
  String toString() => 'ServerMusicProviderSetupSubmission(redacted)';
}
