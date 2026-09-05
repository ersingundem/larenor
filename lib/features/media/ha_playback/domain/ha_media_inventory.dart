import 'ha_playback_models.dart';

/// Integration/class evidence, not codec or physical-device certification.
enum HaMediaReceiverKind {
  castAudio,
  castDisplay,
  appleAudio,
  appleTv,
  audio,
  display,
  unknown,
}

class HaMediaTarget {
  const HaMediaTarget({
    required this.entityId,
    required this.name,
    required this.state,
    required this.supportedFeatures,
    required this.enabled,
    this.deviceClass,
    this.platform,
    this.registryId,
    this.deviceId,
    this.configEntryId,
    this.lastUpdated,
    this.mediaContentId,
    this.mediaTitle,
    this.mediaArtist,
    this.mediaAlbum,
    this.durationSeconds,
    this.positionSeconds,
    this.volumeLevel,
    this.isVolumeMuted,
  });
  final String entityId, name, state;
  final int supportedFeatures;
  final bool enabled;
  final String? deviceClass, platform, registryId, deviceId, configEntryId;
  final DateTime? lastUpdated;
  // Only token-free media-source identities are kept. Resolved URLs are omitted.
  final String? mediaContentId;
  final String? mediaTitle, mediaArtist, mediaAlbum;
  final double? durationSeconds, positionSeconds, volumeLevel;
  final bool? isVolumeMuted;
  bool get available => !{'unknown', 'unavailable'}.contains(state);
  bool get supportsPlayMedia => supportedFeatures & 512 != 0;
  bool get supportsBrowseMedia => supportedFeatures & 131072 != 0;
  bool get hasRegistryIdentity => registryId != null && platform != null;
  bool get isDisplay => {'tv', 'projector'}.contains(deviceClass);
  HaMediaReceiverKind get receiverKind {
    if (platform == 'cast') {
      return isDisplay
          ? HaMediaReceiverKind.castDisplay
          : deviceClass == 'speaker'
          ? HaMediaReceiverKind.castAudio
          : HaMediaReceiverKind.unknown;
    }
    if (platform == 'apple_tv') {
      return deviceClass == 'speaker'
          ? HaMediaReceiverKind.appleAudio
          : HaMediaReceiverKind.appleTv;
    }
    return isDisplay
        ? HaMediaReceiverKind.display
        : deviceClass == 'speaker'
        ? HaMediaReceiverKind.audio
        : HaMediaReceiverKind.unknown;
  }

  bool sameIdentity(HaMediaTarget other) =>
      entityId == other.entityId &&
      registryId == other.registryId &&
      platform == other.platform &&
      deviceId == other.deviceId &&
      configEntryId == other.configEntryId;
  bool canPlay(HaMediaNode source, HaMediaInventory inventory) =>
      inventory.hasPlayMedia &&
      inventory.registryAvailable &&
      hasRegistryIdentity &&
      enabled &&
      available &&
      supportsPlayMedia &&
      source.playable &&
      (source.isAudio ||
          (source.isVideo && isDisplay && platform != 'apple_tv'));
}

class HaMediaInventory {
  HaMediaInventory({
    required List<HaMediaTarget> targets,
    required Map<String, dynamic> services,
    required this.readAt,
    required this.registryAvailable,
    this.registryFailure,
  }) : targets = List.unmodifiable(targets),
       services = _freeze(services) as Map<String, dynamic>;
  final List<HaMediaTarget> targets;
  final Map<String, dynamic> services;
  final DateTime readAt;
  final bool registryAvailable;
  final HaPlaybackFailure? registryFailure;
  bool get hasPlayMedia {
    final domain = services['media_player'];
    if (domain is! Map) return false;
    final service = domain['play_media'];
    if (service is! Map) return false;
    final fields = service['fields'];
    if (fields is! Map) return false;
    // Current HA publishes a media selector; older versions publish two fields.
    return fields['media'] is Map ||
        (fields['media_content_id'] is Map &&
            fields['media_content_type'] is Map);
  }
}

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(
      value.map((key, value) => MapEntry(key as String, _freeze(value))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}

void _validateJson(Object? value, {int depth = 0, List<int>? budget}) {
  final remaining = budget ?? [100000];
  if (--remaining[0] < 0 || depth > 16) invalidHaMedia();
  if (value is Map) {
    if (value.length > 10000 ||
        value.keys.any((key) => key is! String || key.length > 512)) {
      invalidHaMedia();
    }
    for (final v in value.values) {
      _validateJson(v, depth: depth + 1, budget: remaining);
    }
  } else if (value is List) {
    if (value.length > 10000) invalidHaMedia();
    for (final v in value) {
      _validateJson(v, depth: depth + 1, budget: remaining);
    }
  } else if (!(value == null ||
          value is bool ||
          value is String ||
          value is num) ||
      (value is String && value.length > 10000) ||
      (value is num && !value.isFinite)) {
    invalidHaMedia();
  }
}

HaMediaInventory parseHaMediaInventory({
  required Object? states,
  required Object? services,
  required Object? registry,
  required DateTime readAt,
  HaPlaybackFailure? registryFailure,
}) {
  final serviceMap = haMediaObject(services, limit: 2000);
  _validateJson(serviceMap);
  if (states is! List || states.length > 50000) invalidHaMedia();
  if (registry != null && (registry is! List || registry.length > 50000)) {
    invalidHaMedia();
  }
  final registryRows = <String, Map<String, dynamic>>{};
  for (final raw in (registry as List? ?? const [])) {
    final row = haMediaObject(raw);
    final id = haMediaText(row['entity_id']);
    if (id == null || registryRows.containsKey(id)) invalidHaMedia();
    registryRows[id] = row;
  }
  final seen = <String>{};
  final targets = <HaMediaTarget>[];
  for (final raw in states) {
    final row = haMediaObject(raw);
    final id = haMediaText(row['entity_id']);
    if (id == null || !seen.add(id)) invalidHaMedia();
    if (!id.startsWith('media_player.')) continue;
    if (!RegExp(r'^media_player\.[a-z0-9_]+$').hasMatch(id)) invalidHaMedia();
    final state = haMediaText(row['state'], limit: 64);
    final attrs = haMediaObject(row['attributes']);
    final features = attrs['supported_features'];
    if (state == null ||
        (features != null &&
            (features is! int || features < 0 || features > 0x7fffffff))) {
      invalidHaMedia();
    }
    final reg = registryRows[id];
    final updated = haMediaText(row['last_updated'], limit: 64);
    final lastUpdated = updated == null ? null : DateTime.tryParse(updated);
    if (updated != null &&
        (lastUpdated == null ||
            !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(updated))) {
      invalidHaMedia();
    }
    String? contentId;
    final rawId = attrs['media_content_id'];
    if (rawId is String && rawId.startsWith('media-source://')) {
      try {
        contentId = haMediaSourceId(rawId, allowRoot: false);
      } on HaPlaybackException {
        /* Omit unsafe identifiers. */
      }
    }
    targets.add(
      HaMediaTarget(
        entityId: id,
        name: haMediaText(attrs['friendly_name']) ?? id,
        state: state,
        supportedFeatures: features as int? ?? 0,
        enabled:
            reg == null ||
            (reg['disabled_by'] == null && reg['hidden_by'] == null),
        deviceClass: haMediaText(attrs['device_class'], limit: 64),
        platform: haMediaText(reg?['platform'], limit: 128),
        registryId: haMediaText(reg?['id'], limit: 128),
        deviceId: haMediaText(reg?['device_id'], limit: 128),
        configEntryId: haMediaText(reg?['config_entry_id'], limit: 128),
        lastUpdated: lastUpdated?.toUtc(),
        mediaContentId: contentId,
        mediaTitle: haMediaText(attrs['media_title']),
        mediaArtist: haMediaText(attrs['media_artist']),
        mediaAlbum: haMediaText(attrs['media_album_name']),
        durationSeconds: _number(attrs['media_duration'], 2592000),
        positionSeconds: _number(attrs['media_position'], 2592000),
        volumeLevel: _number(attrs['volume_level'], 1),
        isVolumeMuted: _boolean(attrs['is_volume_muted']),
      ),
    );
  }
  targets.sort((a, b) => a.entityId.compareTo(b.entityId));
  return HaMediaInventory(
    targets: targets,
    services: serviceMap,
    readAt: readAt,
    registryAvailable: registry != null,
    registryFailure: registryFailure,
  );
}

double? _number(Object? value, double maximum) {
  if (value == null) return null;
  if (value is! num || !value.isFinite || value < 0 || value > maximum) {
    invalidHaMedia();
  }
  return value.toDouble();
}

bool? _boolean(Object? value) {
  if (value != null && value is! bool) invalidHaMedia();
  return value as bool?;
}
