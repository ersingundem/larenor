import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/server_models.dart';
import '../../plugins/domain/server_plugin_models.dart';

const mediaComponentOrder = [
  'qbittorrent',
  'sonarr',
  'radarr',
  'jellyfin',
  'seerr',
  'music_assistant',
];
const mediaStepKinds = [
  'prepare_storage',
  'create_container',
  'start_container',
  'bootstrap',
  'verify_service',
];
const mediaBlockers = [
  'managed_install_unavailable',
  'host_preflight_required',
  'private_bootstrap_required',
  'auto_wiring_required',
];
Never _invalid() => throw const LarenorServerException('invalid_response');
Map<String, dynamic> mediaObject(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

String _pattern(Object? value, String pattern, int max) {
  if (value is! String ||
      value.length > max ||
      !RegExp(pattern).hasMatch(value)) {
    _invalid();
  }
  return value;
}

String mediaId(Object? value) => _pattern(value, r'^[a-f0-9]{32}$', 32);
String _digest(Object? value) => _pattern(value, r'^[a-f0-9]{64}$', 64);
String _platform(Object? value) {
  if (value != 'linux/amd64' && value != 'linux/arm64') _invalid();
  return value as String;
}

int mediaInteger(Object? value, {int min = 1, int max = 0x7fffffffffffffff}) {
  if (value is! int || value < min || value > max) _invalid();
  return value;
}

DateTime _time(Object? value) {
  final text = _pattern(
    value,
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
    24,
  );
  final date = DateTime.tryParse(text);
  if (date == null || date.toIso8601String() != text) _invalid();
  return date;
}

List<dynamic> _list(Object? value, int count) {
  if (value is! List || value.length != count) _invalid();
  return value;
}

Object? _canonical(Object? value) {
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

class MediaPreparationSettings {
  const MediaPreparationSettings._(
    this.instanceName,
    this.dataRootId,
    this.libraryRootId,
    this.musicRootId,
  );
  factory MediaPreparationSettings.fromJson(Object? value) {
    final map = mediaObject(value, {
      'instanceName',
      'dataRootId',
      'libraryRootId',
      'musicRootId',
    });
    String root(Object? value) =>
        _pattern(value, r'^[a-z][a-z0-9_-]{0,31}$', 32);
    return MediaPreparationSettings._(
      _pattern(map['instanceName'], r'^[a-z][a-z0-9-]{0,19}$', 20),
      root(map['dataRootId']),
      root(map['libraryRootId']),
      map['musicRootId'] == null ? null : root(map['musicRootId']),
    );
  }
  final String instanceName, dataRootId, libraryRootId;
  final String? musicRootId;
  Map<String, Object?> toJson() => {
    'instanceName': instanceName,
    'dataRootId': dataRootId,
    'libraryRootId': libraryRootId,
    'musicRootId': musicRootId,
  };
  Map<String, Object?> componentSettings(String service) => {
    'instanceName': '$instanceName-${service.replaceAll('_', '-')}',
    'dataRootId': dataRootId,
    if (['qbittorrent', 'sonarr', 'radarr'].contains(service))
      'libraryRootId': libraryRootId,
    if (service == 'jellyfin') 'mediaRootId': libraryRootId,
    if (service == 'music_assistant') 'musicRootId': musicRootId,
  };
  bool sameAs(MediaPreparationSettings other) =>
      instanceName == other.instanceName &&
      dataRootId == other.dataRootId &&
      libraryRootId == other.libraryRootId &&
      musicRootId == other.musicRootId;
}

class MediaStackComponent {
  MediaStackComponent._(
    this.serviceId,
    this.installationId,
    this.operationId,
    this.plan,
    this.stepIds,
  );
  final String serviceId, installationId, operationId;
  final PluginInstallPlan plan;
  final List<String> stepIds;
  factory MediaStackComponent.fromJson(Object? value) {
    final map = mediaObject(value, {
      'serviceId',
      'installationId',
      'operationId',
      'plan',
      'steps',
    });
    final plan = PluginInstallPlan.fromJson(map['plan']);
    if (map['serviceId'] != plan.serviceId) _invalid();
    final steps = _list(map['steps'], mediaStepKinds.length);
    final ids = <String>[];
    for (var i = 0; i < steps.length; i++) {
      final step = mediaObject(steps[i], {'kind', 'stepId'});
      if (step['kind'] != mediaStepKinds[i]) _invalid();
      ids.add(mediaId(step['stepId']));
    }
    return MediaStackComponent._(
      plan.serviceId,
      mediaId(map['installationId']),
      mediaId(map['operationId']),
      plan,
      List.unmodifiable(ids),
    );
  }
}

class MediaStackPlan {
  MediaStackPlan._(Map<String, dynamic> map)
    : coreId = mediaId(map['coreId']),
      homeId = mediaId(map['homeId']),
      preparationId = mediaId(map['preparationId']),
      platform = _platform(map['platform']),
      settings = MediaPreparationSettings.fromJson(map['settings']),
      catalogDigest = _digest(map['catalogDigest']),
      planHash = _digest(map['planHash']),
      components = List.unmodifiable(
        _list(map['components'], 6).map(MediaStackComponent.fromJson),
      ) {
    mediaInteger(map['schemaVersion'], max: 1);
    if (map['templateId'] != 'media' ||
        map['installAvailable'] != false ||
        map['bootstrapExposure'] != 'unverified') {
      _invalid();
    }
    final blockers = _list(map['blockers'], 4);
    for (var i = 0; i < blockers.length; i++) {
      if (blockers[i] != mediaBlockers[i]) _invalid();
    }
    final resources = mediaObject(map['requestedResources'], {
      'memoryMiB',
      'cpuMillis',
      'pidsLimit',
      'minimumDiskMiB',
    });
    final totals = [0, 0, 0, 0];
    for (var i = 0; i < components.length; i++) {
      final child = components[i];
      if (child.serviceId != mediaComponentOrder[i] ||
          child.plan.catalogDigest != catalogDigest ||
          child.plan.image.platform != platform) {
        _invalid();
      }
      final requested = settings.componentSettings(child.serviceId);
      if (requested.entries.any(
        (entry) => child.plan.settings[entry.key] != entry.value,
      )) {
        _invalid();
      }
      String identity(String kind, [String step = '']) => sha256
          .convert(
            utf8.encode(
              [
                'larenor-media-stack-v1',
                kind,
                coreId,
                homeId,
                preparationId,
                child.serviceId,
                step,
              ].join('\u0000'),
            ),
          )
          .toString()
          .substring(0, 32);
      if (child.installationId != identity('installation') ||
          child.operationId != identity('operation')) {
        _invalid();
      }
      for (var j = 0; j < child.stepIds.length; j++) {
        if (child.stepIds[j] != identity('step', mediaStepKinds[j])) _invalid();
      }
      final r = child.plan.effects.resources;
      totals[0] += r.memoryMiB;
      totals[1] += r.cpuMillis;
      totals[2] += r.pidsLimit;
      totals[3] += r.minimumDiskMiB;
    }
    memoryMiB = mediaInteger(resources['memoryMiB'], min: 0, max: 6 * 16384);
    cpuMillis = mediaInteger(resources['cpuMillis'], min: 0, max: 6 * 16000);
    pidsLimit = mediaInteger(resources['pidsLimit'], min: 0, max: 6 * 4096);
    minimumDiskMiB = mediaInteger(
      resources['minimumDiskMiB'],
      min: 0,
      max: 6 * 1048576,
    );
    final supplied = [memoryMiB, cpuMillis, pidsLimit, minimumDiskMiB];
    for (var i = 0; i < totals.length; i++) {
      if (supplied[i] != totals[i]) _invalid();
    }
    final bytes = utf8.encode(
      jsonEncode(_canonical({...map}..remove('planHash'))),
    );
    if (bytes.length > 65536 || sha256.convert(bytes).toString() != planHash) {
      _invalid();
    }
  }
  factory MediaStackPlan.fromJson(Object? value) => MediaStackPlan._(
    mediaObject(value, {
      'schemaVersion',
      'templateId',
      'coreId',
      'homeId',
      'preparationId',
      'platform',
      'settings',
      'catalogDigest',
      'planHash',
      'installAvailable',
      'bootstrapExposure',
      'blockers',
      'requestedResources',
      'components',
    }),
  );
  final String coreId, homeId, preparationId, platform, catalogDigest, planHash;
  final MediaPreparationSettings settings;
  final List<MediaStackComponent> components;
  late final int memoryMiB, cpuMillis, pidsLimit, minimumDiskMiB;
  bool get installAvailable => false;
}

class ServerMediaPreparation {
  ServerMediaPreparation._(
    this.id,
    this.requestId,
    this.revision,
    this.state,
    this.createdAt,
    this.updatedAt,
    this.catalogCurrent,
    this.plan,
  );
  factory ServerMediaPreparation.fromJson(Object? value) {
    final map = mediaObject(value, {
      'id',
      'requestId',
      'revision',
      'state',
      'createdAt',
      'updatedAt',
      'catalogCurrent',
      'plan',
    });
    final id = mediaId(map['id']);
    final revision = mediaInteger(map['revision'], max: 2);
    final state = map['state'];
    if ((state != 'prepared' || revision != 1) &&
        (state != 'cancelled' || revision != 2)) {
      _invalid();
    }
    final created = _time(map['createdAt']), updated = _time(map['updatedAt']);
    if (updated.isBefore(created) || map['catalogCurrent'] is! bool) _invalid();
    final plan = MediaStackPlan.fromJson(map['plan']);
    if (plan.preparationId != id) _invalid();
    return ServerMediaPreparation._(
      id,
      mediaId(map['requestId']),
      revision,
      state as String,
      created,
      updated,
      map['catalogCurrent'] as bool,
      plan,
    );
  }
  final String id, requestId, state;
  final int revision;
  final DateTime createdAt, updatedAt;
  final bool catalogCurrent;
  final MediaStackPlan plan;
  bool get prepared => state == 'prepared';
  bool sameIdentity(ServerMediaPreparation other) =>
      id == other.id &&
      requestId == other.requestId &&
      createdAt == other.createdAt &&
      plan.planHash == other.plan.planHash;
}

class MediaPreparationRequest {
  MediaPreparationRequest({
    required String requestId,
    required this.context,
    required this.catalog,
    required String platform,
    required this.settings,
  }) : requestId = mediaId(requestId),
       platform = _platform(platform);
  final String requestId, platform;
  final ServerContext context;
  final ServerPluginCatalog catalog;
  final MediaPreparationSettings settings;
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'templateId': 'media',
    'context': context.toJson(),
    'catalogDigest': catalog.digest,
    'platform': platform,
    'settings': settings.toJson(),
  };
  bool accepts(ServerMediaPreparation record) {
    final plan = record.plan;
    if (record.requestId != requestId ||
        plan.coreId != context.coreId ||
        plan.homeId != context.homeId ||
        plan.catalogDigest != catalog.digest ||
        plan.platform != platform ||
        !plan.settings.sameAs(settings)) {
      return false;
    }
    for (final component in plan.components) {
      final entries = catalog.entries.where(
        (entry) => entry.manifest.serviceId == component.serviceId,
      );
      if (entries.length != 1) return false;
      final expected = {
        for (final spec in entries.single.manifest.settings)
          spec.name: spec.defaultValue,
        ...settings.componentSettings(component.serviceId),
      };
      if (!component.plan.matches(entries.single, platform, expected)) {
        return false;
      }
    }
    return true;
  }
}
