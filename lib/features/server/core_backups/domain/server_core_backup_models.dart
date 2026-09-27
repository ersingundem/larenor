import '../../domain/server_models.dart';

const _maxCoreDatabaseBytes = 128 * 1024 * 1024;
const _maxFamilyBoardBytes = 32 * 1024 * 1024;
const _maxComponentVolumeBytes = 64 * 1024 * 1024;
const _maxComponentBytes = 256 * 1024 * 1024;

enum CoreBackupResourceKind {
  database,
  vaultKey,
  configuration,
  componentData,
  familyBoard,
}

final class CoreBackupResource {
  const CoreBackupResource({
    required this.id,
    required this.kind,
    required this.version,
    required this.byteLength,
    required this.sha256,
  });

  factory CoreBackupResource.fromJson(Object? raw) {
    final json = serverObject(raw);
    if (json.length != 5 ||
        !json.keys.every(
          const {'id', 'kind', 'version', 'byteLength', 'sha256'}.contains,
        )) {
      throw const LarenorServerException('invalid_response');
    }
    final id = json['id'];
    final version = json['version'];
    final bytes = json['byteLength'];
    final digest = json['sha256'];
    final kind = switch (json['kind']) {
      'database' => CoreBackupResourceKind.database,
      'vaultKey' => CoreBackupResourceKind.vaultKey,
      'configuration' => CoreBackupResourceKind.configuration,
      'componentData' => CoreBackupResourceKind.componentData,
      'familyBoard' => CoreBackupResourceKind.familyBoard,
      _ => throw const LarenorServerException('invalid_response'),
    };
    if (id is! String ||
        !RegExp(r'^[a-z][a-z0-9-]{0,39}$').hasMatch(id) ||
        version is! String ||
        !RegExp(r'^[A-Za-z0-9_.+-]{1,64}$').hasMatch(version) ||
        bytes is! int ||
        bytes < 1 ||
        bytes > 512 * 1024 * 1024 ||
        digest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreBackupResource(
      id: id,
      kind: kind,
      version: version,
      byteLength: bytes,
      sha256: digest,
    );
  }

  final String id;
  final CoreBackupResourceKind kind;
  final String version;
  final int byteLength;
  final String sha256;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': switch (kind) {
      CoreBackupResourceKind.database => 'database',
      CoreBackupResourceKind.vaultKey => 'vaultKey',
      CoreBackupResourceKind.configuration => 'configuration',
      CoreBackupResourceKind.componentData => 'componentData',
      CoreBackupResourceKind.familyBoard => 'familyBoard',
    },
    'version': version,
    'byteLength': byteLength,
    'sha256': sha256,
  };

  @override
  String toString() => 'CoreBackupResource($id, ${kind.name})';
}

final class CoreBackupComponent {
  const CoreBackupComponent({
    required this.serviceId,
    required this.serviceVersion,
    required this.configSchemaVersion,
    required this.dataSchemaVersion,
    required this.volumeResourceIds,
  });

  factory CoreBackupComponent.fromJson(Object? raw) {
    final json = serverObject(raw);
    const keys = {
      'serviceId',
      'serviceVersion',
      'configSchemaVersion',
      'dataSchemaVersion',
      'volumeResourceIds',
    };
    final serviceId = json['serviceId'];
    final serviceVersion = json['serviceVersion'];
    final configSchemaVersion = json['configSchemaVersion'];
    final dataSchemaVersion = json['dataSchemaVersion'];
    final rawVolumes = json['volumeResourceIds'];
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        serviceId is! String ||
        !RegExp(r'^[a-z][a-z0-9_]{0,31}$').hasMatch(serviceId) ||
        serviceVersion is! String ||
        !RegExp(r'^[A-Za-z0-9_.+-]{1,64}$').hasMatch(serviceVersion) ||
        configSchemaVersion is! int ||
        configSchemaVersion < 1 ||
        configSchemaVersion > 0x7fffffff ||
        dataSchemaVersion is! String ||
        !RegExp(r'^[A-Za-z0-9_.+-]{1,64}$').hasMatch(dataSchemaVersion) ||
        rawVolumes is! List ||
        rawVolumes.isEmpty ||
        rawVolumes.length > 3 ||
        rawVolumes.any((item) => item is! String)) {
      throw const LarenorServerException('invalid_response');
    }
    final volumes = rawVolumes.cast<String>();
    final prefix = 'component-${serviceId.replaceAll('_', '-')}-';
    if (volumes.toSet().length != volumes.length ||
        volumes.join('\u0000') !=
            (List<String>.of(volumes)..sort()).join('\u0000') ||
        volumes.any(
          (item) =>
              !RegExp(r'^[a-z][a-z0-9-]{0,39}$').hasMatch(item) ||
              !item.startsWith(prefix),
        )) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreBackupComponent(
      serviceId: serviceId,
      serviceVersion: serviceVersion,
      configSchemaVersion: configSchemaVersion,
      dataSchemaVersion: dataSchemaVersion,
      volumeResourceIds: List.unmodifiable(volumes),
    );
  }

  final String serviceId;
  final String serviceVersion;
  final int configSchemaVersion;
  final String dataSchemaVersion;
  final List<String> volumeResourceIds;

  Map<String, dynamic> toJson() => {
    'serviceId': serviceId,
    'serviceVersion': serviceVersion,
    'configSchemaVersion': configSchemaVersion,
    'dataSchemaVersion': dataSchemaVersion,
    'volumeResourceIds': List<String>.of(volumeResourceIds),
  };

  @override
  String toString() => 'CoreBackupComponent($serviceId)';
}

final class CoreBackupConsistencyBoundary {
  const CoreBackupConsistencyBoundary._();

  factory CoreBackupConsistencyBoundary.fromJson(Object? raw) {
    final json = serverObject(raw);
    if (json.length != 2 ||
        json['mode'] != 'core_write_lock_and_component_quiescence' ||
        json['maxDurationSeconds'] != 5) {
      throw const LarenorServerException('invalid_response');
    }
    return const CoreBackupConsistencyBoundary._();
  }

  int get maxDurationSeconds => 5;

  Map<String, dynamic> toJson() => {
    'mode': 'core_write_lock_and_component_quiescence',
    'maxDurationSeconds': maxDurationSeconds,
  };

  @override
  String toString() => 'CoreBackupConsistencyBoundary';
}

final class CoreBackupManifest {
  const CoreBackupManifest({
    required this.contractVersion,
    required this.snapshotId,
    required this.createdAt,
    required this.coreVersion,
    required this.databaseSchemaVersion,
    required this.componentSchemaVersions,
    required this.components,
    required this.consistencyBoundary,
    required this.resources,
  });

  factory CoreBackupManifest.fromJson(Object? raw) {
    final json = serverObject(raw);
    const legacyKeys = {
      'contractVersion',
      'snapshotId',
      'createdAt',
      'coreVersion',
      'databaseSchemaVersion',
      'componentSchemaVersions',
      'resources',
    };
    const componentKeys = {...legacyKeys, 'components', 'consistencyBoundary'};
    final snapshot = json['snapshotId'];
    final created = json['createdAt'];
    final coreVersion = json['coreVersion'];
    final databaseVersion = json['databaseSchemaVersion'];
    final rawComponents = json['componentSchemaVersions'];
    final contractVersion = json['contractVersion'];
    final hasLegacyContract =
        contractVersion == 1 &&
        json.length == legacyKeys.length &&
        json.keys.every(legacyKeys.contains);
    final hasComponentContract =
        contractVersion == 2 &&
        json.length == componentKeys.length &&
        json.keys.every(componentKeys.contains);
    final rawManagedComponents = json['components'];
    final rawBoundary = json['consistencyBoundary'];
    final rawResources = json['resources'];
    if ((!hasLegacyContract && !hasComponentContract) ||
        (contractVersion != 1 && contractVersion != 2) ||
        snapshot is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(snapshot) ||
        created is! int ||
        created < 0 ||
        created > 0x7fffffffffffffff ||
        coreVersion is! String ||
        !RegExp(r'^[A-Za-z0-9_.+-]{1,64}$').hasMatch(coreVersion) ||
        databaseVersion is! int ||
        databaseVersion < 1 ||
        databaseVersion > 0x7fffffff ||
        rawComponents is! Map ||
        rawComponents.length > 128 ||
        rawResources is! List ||
        rawResources.length < (contractVersion == 2 ? 5 : 4) ||
        rawResources.length > 133 ||
        (hasComponentContract && rawManagedComponents is! List) ||
        (hasComponentContract && rawManagedComponents.length > 128) ||
        (hasComponentContract && rawBoundary == null)) {
      throw const LarenorServerException('invalid_response');
    }
    final managedComponents = hasComponentContract
        ? (rawManagedComponents! as List)
              .map(CoreBackupComponent.fromJson)
              .toList()
        : <CoreBackupComponent>[];
    final boundary = rawBoundary == null
        ? null
        : CoreBackupConsistencyBoundary.fromJson(rawBoundary);
    if (managedComponents.isNotEmpty && boundary == null ||
        managedComponents.map((item) => item.serviceId).toSet().length !=
            managedComponents.length) {
      throw const LarenorServerException('invalid_response');
    }
    final components = <String, int>{};
    for (final entry in rawComponents.entries) {
      if (entry.key is! String ||
          !RegExp(r'^[A-Za-z0-9_]{1,64}$').hasMatch(entry.key as String) ||
          entry.value is! int ||
          (entry.value as int) < 1 ||
          (entry.value as int) > 0x7fffffff) {
        throw const LarenorServerException('invalid_response');
      }
      components[entry.key as String] = entry.value as int;
    }
    final resources = rawResources.map(CoreBackupResource.fromJson).toList();
    const expected = {
      'component-index': CoreBackupResourceKind.componentData,
      'core-configuration': CoreBackupResourceKind.configuration,
      'core-database': CoreBackupResourceKind.database,
      'vault-key': CoreBackupResourceKind.vaultKey,
    };
    final versionedExpected = {
      ...expected,
      if (contractVersion == 2)
        'family-board': CoreBackupResourceKind.familyBoard,
      for (final component in managedComponents)
        for (final id in component.volumeResourceIds)
          id: CoreBackupResourceKind.componentData,
    };
    if (resources.length != versionedExpected.length ||
        resources.any((item) => versionedExpected[item.id] != item.kind) ||
        resources.map((item) => item.id).toSet().length != resources.length) {
      throw const LarenorServerException('invalid_response');
    }
    DateTime timestamp;
    try {
      timestamp = DateTime.fromMillisecondsSinceEpoch(
        created * 1000,
        isUtc: true,
      );
    } on RangeError {
      throw const LarenorServerException('invalid_response');
    }
    final versions = {for (final item in resources) item.id: item.version};
    final resourcesById = {for (final item in resources) item.id: item};
    final volumeIds = managedComponents
        .expand((item) => item.volumeResourceIds)
        .toList();
    var componentBytes = 0;
    for (final id in volumeIds) {
      final bytes = resourcesById[id]!.byteLength;
      if (bytes > _maxComponentVolumeBytes) {
        throw const LarenorServerException('invalid_response');
      }
      componentBytes += bytes;
    }
    if (volumeIds.toSet().length != volumeIds.length ||
        resourcesById['vault-key']!.byteLength != 32 ||
        resourcesById['core-database']!.byteLength > _maxCoreDatabaseBytes ||
        (contractVersion == 2 &&
            resourcesById['family-board']!.byteLength > _maxFamilyBoardBytes) ||
        componentBytes > _maxComponentBytes ||
        versions['component-index'] != (contractVersion == 1 ? '1' : '2') ||
        versions['core-configuration'] != '1' ||
        versions['core-database'] != '$databaseVersion' ||
        (contractVersion == 2 && versions['family-board'] != '1') ||
        versions['vault-key'] != 'aes256-v1' ||
        volumeIds.any((id) => versions[id] != 'component-v1')) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreBackupManifest(
      contractVersion: contractVersion,
      snapshotId: snapshot,
      createdAt: timestamp,
      coreVersion: coreVersion,
      databaseSchemaVersion: databaseVersion,
      componentSchemaVersions: Map.unmodifiable(components),
      components: List.unmodifiable(managedComponents),
      consistencyBoundary: boundary,
      resources: List.unmodifiable(resources),
    );
  }

  final int contractVersion;
  final String snapshotId;
  final DateTime createdAt;
  final String coreVersion;
  final int databaseSchemaVersion;
  final Map<String, int> componentSchemaVersions;
  final List<CoreBackupComponent> components;
  final CoreBackupConsistencyBoundary? consistencyBoundary;
  final List<CoreBackupResource> resources;
  int get totalBytes =>
      resources.fold(0, (total, item) => total + item.byteLength);

  Map<String, dynamic> toJson() => {
    'contractVersion': contractVersion,
    'snapshotId': snapshotId,
    'createdAt': createdAt.millisecondsSinceEpoch ~/ 1000,
    'coreVersion': coreVersion,
    'databaseSchemaVersion': databaseSchemaVersion,
    'componentSchemaVersions': Map<String, int>.of(componentSchemaVersions),
    if (contractVersion == 2) ...{
      'components': components.map((item) => item.toJson()).toList(),
      'consistencyBoundary': consistencyBoundary!.toJson(),
    },
    'resources': resources.map((item) => item.toJson()).toList(),
  };

  @override
  String toString() => 'CoreBackupManifest';
}

enum CoreBackupCompatibilityReason {
  unsupportedContract,
  databaseSchema,
  coreVersion,
  componentSchema,
  componentVersion,
  componentVolume,
}

final class CoreBackupCompatibility {
  const CoreBackupCompatibility._({
    required this.compatible,
    required this.reasons,
  });

  factory CoreBackupCompatibility.fromJson(Object? raw) {
    final json = serverObject(raw);
    const keys = {'compatible', 'reasons'};
    final compatible = json['compatible'];
    final rawReasons = json['reasons'];
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        compatible is! bool ||
        rawReasons is! List ||
        rawReasons.length > 6) {
      throw const LarenorServerException('invalid_response');
    }
    final reasons = <CoreBackupCompatibilityReason>{};
    for (final rawReason in rawReasons) {
      final reason = switch (rawReason) {
        'unsupported_contract_version' =>
          CoreBackupCompatibilityReason.unsupportedContract,
        'database_schema_mismatch' =>
          CoreBackupCompatibilityReason.databaseSchema,
        'core_version_mismatch' => CoreBackupCompatibilityReason.coreVersion,
        'component_schema_mismatch' =>
          CoreBackupCompatibilityReason.componentSchema,
        'component_version_mismatch' =>
          CoreBackupCompatibilityReason.componentVersion,
        'component_volume_mismatch' =>
          CoreBackupCompatibilityReason.componentVolume,
        _ => throw const LarenorServerException('invalid_response'),
      };
      if (!reasons.add(reason)) {
        throw const LarenorServerException('invalid_response');
      }
    }
    if (compatible == reasons.isNotEmpty) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreBackupCompatibility._(
      compatible: compatible,
      reasons: Set.unmodifiable(reasons),
    );
  }

  final bool compatible;
  final Set<CoreBackupCompatibilityReason> reasons;

  @override
  String toString() => 'CoreBackupCompatibility($compatible)';
}

final class CoreBackupExport {
  const CoreBackupExport({
    required this.destination,
    required this.byteLength,
    required this.sha256,
    required this.captureGeneration,
  });

  static const maxBytes = 168 * 1024 * 1024;
  static const filename = 'larenor-core-backup.larenor-core';
  final Uri destination;
  final int byteLength;
  final String sha256;
  final String captureGeneration;

  @override
  String toString() => 'CoreBackupExport($byteLength bytes)';
}

final class CoreBackupPlan {
  const CoreBackupPlan._({required this.blockers, this.manifest});

  factory CoreBackupPlan.fromJson(Object? raw) {
    final json = serverObject(raw);
    const keys = {'status', 'blockers', 'manifest'};
    final rawBlockers = json['blockers'];
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        rawBlockers is! List ||
        rawBlockers.length > maxBlockers ||
        rawBlockers.any(
          (item) => item is! String || !allowedBlockers.contains(item),
        )) {
      throw const LarenorServerException('invalid_response');
    }
    final blockers = List<String>.unmodifiable(rawBlockers.cast<String>());
    final quiescenceCount = blockers.where(quiescenceBlockers.contains).length;
    if ((quiescenceCount > 0 && blockers.length != 1) ||
        (quiescenceCount == 0 && !_activeBlockersAreCanonical(blockers))) {
      throw const LarenorServerException('invalid_response');
    }
    return switch (json['status']) {
      'ready' when blockers.isEmpty && json['manifest'] != null =>
        CoreBackupPlan._(
          blockers: blockers,
          manifest: CoreBackupManifest.fromJson(json['manifest']),
        ),
      'blocked' when blockers.isNotEmpty && json['manifest'] == null =>
        CoreBackupPlan._(blockers: blockers),
      _ => throw const LarenorServerException('invalid_response'),
    };
  }

  static const allowedBlockers = {
    'active_bounded_transfer',
    'active_plugin_job',
    'active_media_inspection',
    'active_media_installation',
    'active_media_bootstrap',
    'active_qbittorrent_configuration',
    'active_arr_configuration',
    'active_seerr_bootstrap',
    'active_music_assistant_bootstrap',
    'active_keenetic_command',
    'active_tablet_command',
    'component_quiescence_timeout',
    'component_quiescence_unavailable',
  };
  static const maxBlockers = 11;

  static const activeBlockerOrder = [
    'active_bounded_transfer',
    'active_plugin_job',
    'active_media_inspection',
    'active_media_installation',
    'active_media_bootstrap',
    'active_qbittorrent_configuration',
    'active_arr_configuration',
    'active_seerr_bootstrap',
    'active_music_assistant_bootstrap',
    'active_keenetic_command',
    'active_tablet_command',
  ];
  static const quiescenceBlockers = {
    'component_quiescence_timeout',
    'component_quiescence_unavailable',
  };

  static bool _activeBlockersAreCanonical(List<String> blockers) {
    var prior = -1;
    for (final blocker in blockers) {
      final index = activeBlockerOrder.indexOf(blocker);
      if (index <= prior) return false;
      prior = index;
    }
    return true;
  }

  final List<String> blockers;
  final CoreBackupManifest? manifest;
  bool get ready => manifest != null;

  @override
  String toString() => 'CoreBackupPlan(${ready ? 'ready' : 'blocked'})';
}

enum RecoveryDrillState { queued, running, succeeded, failed, cancelled }

enum RecoveryDrillTrigger { manual, monthly }

final class RecoveryDrillReceipt {
  const RecoveryDrillReceipt._({
    required this.outcome,
    required this.startedAt,
    required this.completedAt,
    required this.durationMilliseconds,
    required this.verifiedResources,
    this.failureCode,
  });

  factory RecoveryDrillReceipt.fromJson(Object? raw) {
    final json = serverObject(raw);
    const keys = {
      'contractVersion',
      'outcome',
      'effectPolicy',
      'startedAt',
      'completedAt',
      'durationMilliseconds',
      'verifiedResources',
      'failureCode',
    };
    final outcome = _drillState(json['outcome']);
    final started = _drillTime(json['startedAt']);
    final completed = _drillTime(json['completedAt']);
    final duration = json['durationMilliseconds'];
    final resources = _drillResources(
      json['verifiedResources'],
      allowPartial: true,
    );
    final failure = json['failureCode'];
    const failures = {
      'deadline_exceeded',
      'authority_changed',
      'backup_failed',
      'restore_failed',
      'health_check_failed',
      'cancelled',
      'worker_unavailable',
    };
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        json['contractVersion'] != 1 ||
        json['effectPolicy'] != 'deny_all_production_effects' ||
        !const {
          RecoveryDrillState.succeeded,
          RecoveryDrillState.failed,
          RecoveryDrillState.cancelled,
        }.contains(outcome) ||
        completed.isBefore(started) ||
        duration is! int ||
        duration < 0 ||
        duration > 3600000 ||
        (failure != null &&
            (failure is! String || !failures.contains(failure))) ||
        (outcome == RecoveryDrillState.succeeded) !=
            (failure == null &&
                resources.length == _recoveryResources.length)) {
      throw const LarenorServerException('invalid_response');
    }
    return RecoveryDrillReceipt._(
      outcome: outcome,
      startedAt: started,
      completedAt: completed,
      durationMilliseconds: duration,
      verifiedResources: resources,
      failureCode: failure as String?,
    );
  }

  final RecoveryDrillState outcome;
  final DateTime startedAt, completedAt;
  final int durationMilliseconds;
  final List<String> verifiedResources;
  final String? failureCode;
}

const _recoveryResources = [
  'coreDatabase',
  'vaultKey',
  'configuration',
  'familyBoard',
  'componentData',
];

RecoveryDrillState _drillState(Object? raw) => switch (raw) {
  'queued' => RecoveryDrillState.queued,
  'running' => RecoveryDrillState.running,
  'succeeded' => RecoveryDrillState.succeeded,
  'failed' => RecoveryDrillState.failed,
  'cancelled' => RecoveryDrillState.cancelled,
  _ => throw const LarenorServerException('invalid_response'),
};

DateTime _drillTime(Object? raw) {
  if (raw is! int || raw < 0 || raw > 253402300799) {
    throw const LarenorServerException('invalid_response');
  }
  try {
    return DateTime.fromMillisecondsSinceEpoch(raw * 1000, isUtc: true);
  } on RangeError {
    throw const LarenorServerException('invalid_response');
  }
}

List<String> _drillResources(Object? raw, {required bool allowPartial}) {
  if (raw is! List ||
      raw.length > _recoveryResources.length ||
      (!allowPartial && raw.length != _recoveryResources.length) ||
      raw.any((item) => item is! String)) {
    throw const LarenorServerException('invalid_response');
  }
  final values = raw.cast<String>();
  if (values.join('\u0000') !=
      _recoveryResources.take(values.length).join('\u0000')) {
    throw const LarenorServerException('invalid_response');
  }
  return List.unmodifiable(values);
}

final class RecoveryDrill {
  const RecoveryDrill._({
    required this.id,
    required this.requestId,
    required this.trigger,
    required this.deadlineSeconds,
    required this.revision,
    required this.state,
    required this.cancelRequested,
    required this.createdAt,
    required this.updatedAt,
    this.receipt,
  });

  factory RecoveryDrill.fromJson(Object? raw) {
    final json = serverObject(raw);
    const keys = {
      'id',
      'requestId',
      'contractVersion',
      'mode',
      'trigger',
      'scope',
      'deadlineSeconds',
      'revision',
      'state',
      'cancelRequested',
      'createdAt',
      'updatedAt',
      'receipt',
    };
    final id = json['id'], requestId = json['requestId'];
    final deadline = json['deadlineSeconds'], revision = json['revision'];
    final state = _drillState(json['state']);
    final created = _drillTime(json['createdAt']);
    final updated = _drillTime(json['updatedAt']);
    _drillResources(json['scope'], allowPartial: false);
    final receipt = json['receipt'] == null
        ? null
        : RecoveryDrillReceipt.fromJson(json['receipt']);
    final terminal = const {
      RecoveryDrillState.succeeded,
      RecoveryDrillState.failed,
      RecoveryDrillState.cancelled,
    }.contains(state);
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        id is! String ||
        requestId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
        json['contractVersion'] != 1 ||
        json['mode'] != 'isolated_full_restore' ||
        deadline is! int ||
        deadline < 60 ||
        deadline > 3600 ||
        revision is! int ||
        revision < 1 ||
        revision > 0x7ffffffffffffffe ||
        json['cancelRequested'] is! bool ||
        updated.isBefore(created) ||
        terminal != (receipt != null) ||
        (receipt != null && receipt.outcome != state)) {
      throw const LarenorServerException('invalid_response');
    }
    final trigger = switch (json['trigger']) {
      'manual' => RecoveryDrillTrigger.manual,
      'monthly' => RecoveryDrillTrigger.monthly,
      _ => throw const LarenorServerException('invalid_response'),
    };
    return RecoveryDrill._(
      id: id,
      requestId: requestId,
      trigger: trigger,
      deadlineSeconds: deadline,
      revision: revision,
      state: state,
      cancelRequested: json['cancelRequested'] as bool,
      createdAt: created,
      updatedAt: updated,
      receipt: receipt,
    );
  }

  final String id, requestId;
  final RecoveryDrillTrigger trigger;
  final int deadlineSeconds, revision;
  final RecoveryDrillState state;
  final bool cancelRequested;
  final DateTime createdAt, updatedAt;
  final RecoveryDrillReceipt? receipt;
  bool get active =>
      state == RecoveryDrillState.queued || state == RecoveryDrillState.running;
}

final class RecoveryDrillSchedule {
  const RecoveryDrillSchedule._({
    required this.revision,
    required this.enabled,
    this.nextRunAt,
  });

  factory RecoveryDrillSchedule.fromJson(Object? raw) {
    final json = serverObject(raw);
    const keys = {
      'contractVersion',
      'revision',
      'enabled',
      'intervalDays',
      'nextRunAt',
    };
    final revision = json['revision'], enabled = json['enabled'];
    final next = json['nextRunAt'] == null
        ? null
        : _drillTime(json['nextRunAt']);
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        json['contractVersion'] != 1 ||
        revision is! int ||
        revision < 0 ||
        revision > 0x7ffffffffffffffe ||
        enabled is! bool ||
        json['intervalDays'] != 30 ||
        enabled != (next != null)) {
      throw const LarenorServerException('invalid_response');
    }
    return RecoveryDrillSchedule._(
      revision: revision,
      enabled: enabled,
      nextRunAt: next,
    );
  }

  final int revision;
  final bool enabled;
  final DateTime? nextRunAt;
}

final class ImmutableBackupTarget {
  const ImmutableBackupTarget._({
    required this.revision,
    required this.endpoint,
    required this.targetId,
    required this.retentionDays,
    required this.quotaBytes,
    required this.configuredAt,
    required this.nextRunAt,
  });

  factory ImmutableBackupTarget.fromJson(Object? raw) {
    final json = serverObject(raw);
    const keys = {
      'contractVersion',
      'revision',
      'kind',
      'endpoint',
      'targetId',
      'retentionDays',
      'quotaBytes',
      'writerScope',
      'recoveryScope',
      'configuredAt',
      'nextRunAt',
    };
    final revision = json['revision'];
    final endpoint = json['endpoint'];
    final targetId = json['targetId'];
    final retentionDays = json['retentionDays'];
    final quotaBytes = json['quotaBytes'];
    final uri = endpoint is String ? Uri.tryParse(endpoint) : null;
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        json['contractVersion'] != 1 ||
        json['kind'] != 'rest_append_only_v1' ||
        json['writerScope'] != 'append_only' ||
        json['recoveryScope'] != 'read_and_retain' ||
        revision is! int ||
        revision < 1 ||
        endpoint is! String ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        targetId is! String ||
        !RegExp(r'^[a-z][a-z0-9-]{2,63}$').hasMatch(targetId) ||
        retentionDays is! int ||
        retentionDays < 7 ||
        retentionDays > 3650 ||
        quotaBytes is! int ||
        quotaBytes < 64 * 1024 * 1024 ||
        quotaBytes > 10 * 1024 * 1024 * 1024 * 1024) {
      throw const LarenorServerException('invalid_response');
    }
    return ImmutableBackupTarget._(
      revision: revision,
      endpoint: endpoint,
      targetId: targetId,
      retentionDays: retentionDays,
      quotaBytes: quotaBytes,
      configuredAt: _drillTime(json['configuredAt']),
      nextRunAt: _drillTime(json['nextRunAt']),
    );
  }

  final int revision, retentionDays, quotaBytes;
  final String endpoint, targetId;
  final DateTime configuredAt, nextRunAt;
}

final class ImmutableRestorePoint {
  const ImmutableRestorePoint._({
    required this.objectId,
    required this.targetRevision,
    required this.createdAt,
    required this.protectedUntil,
    required this.byteLength,
    required this.sha256,
    required this.remoteReceiptId,
  });

  factory ImmutableRestorePoint.fromJson(Object? raw) {
    final json = serverObject(raw);
    const keys = {
      'objectId',
      'targetRevision',
      'createdAt',
      'protectedUntil',
      'byteLength',
      'sha256',
      'remoteReceiptId',
    };
    final objectId = json['objectId'];
    final revision = json['targetRevision'];
    final bytes = json['byteLength'];
    final digest = json['sha256'];
    final receipt = json['remoteReceiptId'];
    final created = _drillTime(json['createdAt']);
    final protected = _drillTime(json['protectedUntil']);
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        objectId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(objectId) ||
        revision is! int ||
        revision < 1 ||
        bytes is! int ||
        bytes < 1 ||
        bytes > 512 * 1024 * 1024 ||
        digest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        receipt is! String ||
        !RegExp(r'^[A-Za-z0-9_.:-]{1,128}$').hasMatch(receipt) ||
        !protected.isAfter(created)) {
      throw const LarenorServerException('invalid_response');
    }
    return ImmutableRestorePoint._(
      objectId: objectId,
      targetRevision: revision,
      createdAt: created,
      protectedUntil: protected,
      byteLength: bytes,
      sha256: digest,
      remoteReceiptId: receipt,
    );
  }

  final String objectId, sha256, remoteReceiptId;
  final int targetRevision, byteLength;
  final DateTime createdAt, protectedUntil;
}

final class ImmutableRestorePoints {
  const ImmutableRestorePoints._({
    required this.points,
    required this.quotaUsedBytes,
    required this.quotaBytes,
  });

  factory ImmutableRestorePoints.fromJson(Object? raw) {
    final json = serverObject(raw);
    const keys = {'points', 'quotaUsedBytes', 'quotaBytes'};
    final rawPoints = json['points'];
    final used = json['quotaUsedBytes'];
    final quota = json['quotaBytes'];
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        rawPoints is! List ||
        rawPoints.length > 100 ||
        used is! int ||
        used < 0 ||
        quota is! int ||
        quota < 64 * 1024 * 1024 ||
        used > quota) {
      throw const LarenorServerException('invalid_response');
    }
    return ImmutableRestorePoints._(
      points: List.unmodifiable(rawPoints.map(ImmutableRestorePoint.fromJson)),
      quotaUsedBytes: used,
      quotaBytes: quota,
    );
  }

  final List<ImmutableRestorePoint> points;
  final int quotaUsedBytes, quotaBytes;
}
