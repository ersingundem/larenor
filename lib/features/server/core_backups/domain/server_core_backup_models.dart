import '../../domain/server_models.dart';

enum CoreBackupResourceKind { database, vaultKey, configuration, componentData }

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

  @override
  String toString() => 'CoreBackupResource($id, ${kind.name})';
}

final class CoreBackupManifest {
  const CoreBackupManifest({
    required this.snapshotId,
    required this.createdAt,
    required this.coreVersion,
    required this.databaseSchemaVersion,
    required this.componentSchemaVersions,
    required this.resources,
  });

  factory CoreBackupManifest.fromJson(Object? raw) {
    final json = serverObject(raw);
    const keys = {
      'contractVersion',
      'snapshotId',
      'createdAt',
      'coreVersion',
      'databaseSchemaVersion',
      'componentSchemaVersions',
      'resources',
    };
    final snapshot = json['snapshotId'];
    final created = json['createdAt'];
    final coreVersion = json['coreVersion'];
    final databaseVersion = json['databaseSchemaVersion'];
    final rawComponents = json['componentSchemaVersions'];
    final rawResources = json['resources'];
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        json['contractVersion'] != 1 ||
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
        rawResources.length != 4) {
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
    if (resources.length != expected.length ||
        resources.any((item) => expected[item.id] != item.kind) ||
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
    if (versions['component-index'] != '1' ||
        versions['core-configuration'] != '1' ||
        versions['core-database'] != '$databaseVersion' ||
        versions['vault-key'] != 'aes256-v1') {
      throw const LarenorServerException('invalid_response');
    }
    return CoreBackupManifest(
      snapshotId: snapshot,
      createdAt: timestamp,
      coreVersion: coreVersion,
      databaseSchemaVersion: databaseVersion,
      componentSchemaVersions: Map.unmodifiable(components),
      resources: List.unmodifiable(resources),
    );
  }

  final String snapshotId;
  final DateTime createdAt;
  final String coreVersion;
  final int databaseSchemaVersion;
  final Map<String, int> componentSchemaVersions;
  final List<CoreBackupResource> resources;
  int get totalBytes =>
      resources.fold(0, (total, item) => total + item.byteLength);

  @override
  String toString() => 'CoreBackupManifest';
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
        rawBlockers.length > allowedBlockers.length ||
        rawBlockers.any(
          (item) => item is! String || !allowedBlockers.contains(item),
        )) {
      throw const LarenorServerException('invalid_response');
    }
    final blockers = List<String>.unmodifiable(rawBlockers.cast<String>());
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
  };

  final List<String> blockers;
  final CoreBackupManifest? manifest;
  bool get ready => manifest != null;

  @override
  String toString() => 'CoreBackupPlan(${ready ? 'ready' : 'blocked'})';
}
