import '../../home_resources/domain/home_resource_models.dart';
import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

String _id(Object? value) {
  if (value is! String ||
      value.length != 32 ||
      !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

String _digest(Object? value) {
  if (value is! String ||
      value.length != 64 ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _integer(Object? value, {int min = 0, int max = 9223372036854775807}) {
  if (value is! int || value < min || value > max) _invalid();
  return value;
}

double _ratio(Object? value) {
  if (value is! num || !value.isFinite || value < 0 || value > 1) _invalid();
  return value.toDouble();
}

String _safe(Object? value, {int max = 128, Pattern? pattern}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value.runes.any(
        (rune) =>
            rune < 32 ||
            rune >= 127 && rune <= 159 ||
            rune >= 0xd800 && rune <= 0xdfff,
      ) ||
      pattern != null && !RegExp(pattern.toString()).hasMatch(value)) {
    _invalid();
  }
  return value;
}

void _ref(Object? raw, HomeResourceRecord target) {
  final value = _object(raw, {
    'schemaVersion',
    'coreId',
    'homeId',
    'kind',
    'id',
  });
  if (value['schemaVersion'] != 1 ||
      target.kind != HomeResourceKind.resource ||
      value['kind'] != 'resource' ||
      value['coreId'] != target.context.coreId ||
      value['homeId'] != target.context.homeId ||
      value['id'] != target.id) {
    _invalid();
  }
}

DateTime _timestamp(Object? raw) {
  if (raw is! String ||
      raw.length > 40 ||
      !RegExp(r'T.*(?:Z|\+00:00)$').hasMatch(raw)) {
    _invalid();
  }
  final value = DateTime.tryParse(raw);
  if (value == null || !value.isUtc) _invalid();
  return value;
}

enum CoreProxmoxNodeStatus { online, offline }

final class CoreProxmoxNode {
  const CoreProxmoxNode._({
    required this.name,
    required this.status,
    required this.cpuRatio,
    required this.memoryUsedBytes,
    required this.memoryTotalBytes,
    required this.uptime,
  });
  final String name;
  final CoreProxmoxNodeStatus status;
  final double cpuRatio;
  final int memoryUsedBytes, memoryTotalBytes;
  final Duration uptime;

  factory CoreProxmoxNode.fromJson(Object? raw) {
    final value = _object(raw, {
      'node',
      'status',
      'cpuRatio',
      'memoryUsedBytes',
      'memoryTotalBytes',
      'uptimeSeconds',
    });
    final used = _integer(value['memoryUsedBytes']),
        total = _integer(value['memoryTotalBytes'], min: 1),
        uptime = _integer(value['uptimeSeconds']);
    if (used > total) _invalid();
    return CoreProxmoxNode._(
      name: _safe(value['node'], max: 64),
      status: switch (value['status']) {
        'online' => CoreProxmoxNodeStatus.online,
        'offline' => CoreProxmoxNodeStatus.offline,
        _ => _invalid(),
      },
      cpuRatio: _ratio(value['cpuRatio']),
      memoryUsedBytes: used,
      memoryTotalBytes: total,
      uptime: Duration(seconds: uptime),
    );
  }
}

enum CoreProxmoxGuestKind { qemu, lxc }

enum CoreProxmoxGuestStatus { running, stopped }

final class CoreProxmoxGuest {
  const CoreProxmoxGuest._({
    required this.vmId,
    required this.node,
    required this.kind,
    required this.name,
    required this.status,
    required this.cpuRatio,
    required this.memoryUsedBytes,
    required this.memoryTotalBytes,
  });
  final int vmId;
  final String node, name;
  final CoreProxmoxGuestKind kind;
  final CoreProxmoxGuestStatus status;
  final double cpuRatio;
  final int memoryUsedBytes, memoryTotalBytes;

  factory CoreProxmoxGuest.fromJson(Object? raw) {
    final value = _object(raw, {
      'vmId',
      'node',
      'kind',
      'name',
      'status',
      'cpuRatio',
      'memoryUsedBytes',
      'memoryTotalBytes',
    });
    final used = _integer(value['memoryUsedBytes']),
        total = _integer(value['memoryTotalBytes'], min: 1);
    if (used > total) _invalid();
    return CoreProxmoxGuest._(
      vmId: _integer(value['vmId'], min: 1, max: 999999999),
      node: _safe(value['node'], max: 64),
      kind: switch (value['kind']) {
        'qemu' => CoreProxmoxGuestKind.qemu,
        'lxc' => CoreProxmoxGuestKind.lxc,
        _ => _invalid(),
      },
      name: _safe(value['name']),
      status: switch (value['status']) {
        'running' => CoreProxmoxGuestStatus.running,
        'stopped' => CoreProxmoxGuestStatus.stopped,
        _ => _invalid(),
      },
      cpuRatio: _ratio(value['cpuRatio']),
      memoryUsedBytes: used,
      memoryTotalBytes: total,
    );
  }
}

final class CoreProxmoxStorage {
  const CoreProxmoxStorage._({
    required this.name,
    required this.node,
    required this.kind,
    required this.active,
    required this.usedBytes,
    required this.totalBytes,
    required this.availableBytes,
  });
  final String name, node, kind;
  final bool active;
  final int usedBytes, totalBytes, availableBytes;
  double get usedRatio => usedBytes / totalBytes;

  factory CoreProxmoxStorage.fromJson(Object? raw) {
    final value = _object(raw, {
      'storage',
      'node',
      'kind',
      'active',
      'usedBytes',
      'totalBytes',
      'availableBytes',
    });
    final used = _integer(value['usedBytes']),
        total = _integer(value['totalBytes'], min: 1),
        available = _integer(value['availableBytes']);
    if (value['active'] is! bool || used > total || available > total) {
      _invalid();
    }
    return CoreProxmoxStorage._(
      name: _safe(value['storage'], max: 64),
      node: _safe(value['node'], max: 64),
      kind: _safe(value['kind'], max: 64),
      active: value['active'] as bool,
      usedBytes: used,
      totalBytes: total,
      availableBytes: available,
    );
  }
}

enum CoreProxmoxTaskStatus { running, succeeded, failed }

final class CoreProxmoxRecentTask {
  const CoreProxmoxRecentTask._({
    required this.id,
    required this.node,
    required this.kind,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
  });

  final String id, node, kind;
  final CoreProxmoxTaskStatus status;
  final DateTime startedAt;
  final DateTime? finishedAt;

  factory CoreProxmoxRecentTask.fromJson(Object? raw) {
    final value = _object(raw, {
      'taskId',
      'node',
      'kind',
      'status',
      'startedAt',
      'finishedAt',
    });
    final status = switch (value['status']) {
      'running' => CoreProxmoxTaskStatus.running,
      'succeeded' => CoreProxmoxTaskStatus.succeeded,
      'failed' => CoreProxmoxTaskStatus.failed,
      _ => _invalid(),
    };
    final started = _timestamp(value['startedAt']);
    final finished = value['finishedAt'] == null
        ? null
        : _timestamp(value['finishedAt']);
    if ((status == CoreProxmoxTaskStatus.running) != (finished == null) ||
        finished != null && finished.isBefore(started)) {
      _invalid();
    }
    return CoreProxmoxRecentTask._(
      id: _digest(value['taskId']),
      node: _safe(
        value['node'],
        max: 64,
        pattern: r'^[A-Za-z0-9][A-Za-z0-9._-]*$',
      ),
      kind: _safe(
        value['kind'],
        max: 64,
        pattern: r'^[A-Za-z0-9][A-Za-z0-9._-]*$',
      ),
      status: status,
      startedAt: started,
      finishedAt: finished,
    );
  }
}

enum CoreProxmoxProtectionState { available, empty, partial }

final class CoreProxmoxGuestSnapshot {
  const CoreProxmoxGuestSnapshot._({
    required this.node,
    required this.kind,
    required this.vmId,
    required this.snapshotCount,
    required this.latestAt,
  });

  final String node;
  final CoreProxmoxGuestKind kind;
  final int vmId, snapshotCount;
  final DateTime? latestAt;

  factory CoreProxmoxGuestSnapshot.fromJson(Object? raw) {
    final value = _object(raw, {
      'node',
      'kind',
      'vmId',
      'snapshotCount',
      'latestAt',
    });
    final count = _integer(value['snapshotCount'], max: 256);
    final latest = value['latestAt'] == null
        ? null
        : _timestamp(value['latestAt']);
    if ((count == 0) != (latest == null)) _invalid();
    return CoreProxmoxGuestSnapshot._(
      node: _safe(
        value['node'],
        max: 64,
        pattern: r'^[A-Za-z0-9][A-Za-z0-9._-]*$',
      ),
      kind: switch (value['kind']) {
        'qemu' => CoreProxmoxGuestKind.qemu,
        'lxc' => CoreProxmoxGuestKind.lxc,
        _ => _invalid(),
      },
      vmId: _integer(value['vmId'], min: 1, max: 999999999),
      snapshotCount: count,
      latestAt: latest,
    );
  }
}

final class CoreProxmoxProtectionSummary {
  const CoreProxmoxProtectionSummary._({
    required this.state,
    required this.guestCount,
    required this.scannedGuestCount,
    required this.truncated,
    required this.latestBackup,
    required this.snapshots,
  });

  final CoreProxmoxProtectionState state;
  final int guestCount, scannedGuestCount;
  final bool truncated;
  final CoreProxmoxRecentTask? latestBackup;
  final List<CoreProxmoxGuestSnapshot> snapshots;

  factory CoreProxmoxProtectionSummary.fromJson(Object? raw) {
    final value = _object(raw, {
      'state',
      'guestCount',
      'scannedGuestCount',
      'truncated',
      'latestBackup',
      'snapshots',
    });
    final source = value['snapshots'];
    if (source is! List || source.length > 8 || value['truncated'] is! bool) {
      _invalid();
    }
    final snapshots = List<CoreProxmoxGuestSnapshot>.unmodifiable(
      source.map(CoreProxmoxGuestSnapshot.fromJson),
    );
    final guestCount = _integer(value['guestCount'], max: 256);
    final scanned = _integer(value['scannedGuestCount'], max: 8);
    final truncated = value['truncated'] as bool;
    final latest = value['latestBackup'] == null
        ? null
        : CoreProxmoxRecentTask.fromJson(value['latestBackup']);
    if (latest != null && latest.kind != 'vzdump' ||
        snapshots.length != scanned ||
        guestCount < scanned ||
        truncated != (guestCount > scanned) ||
        snapshots
                .map((item) => '${item.node}:${item.kind.name}:${item.vmId}')
                .toSet()
                .length !=
            snapshots.length) {
      _invalid();
    }
    final hasData =
        latest != null ||
        snapshots.any((snapshot) => snapshot.snapshotCount > 0);
    final state = switch (value['state']) {
      'available' => CoreProxmoxProtectionState.available,
      'empty' => CoreProxmoxProtectionState.empty,
      'partial' => CoreProxmoxProtectionState.partial,
      _ => _invalid(),
    };
    final expected = truncated
        ? CoreProxmoxProtectionState.partial
        : hasData
        ? CoreProxmoxProtectionState.available
        : CoreProxmoxProtectionState.empty;
    if (state != expected) _invalid();
    return CoreProxmoxProtectionSummary._(
      state: state,
      guestCount: guestCount,
      scannedGuestCount: scanned,
      truncated: truncated,
      latestBackup: latest,
      snapshots: snapshots,
    );
  }
}

enum CoreProxmoxRetentionState { healthy, attention, critical }

enum CoreProxmoxRetentionWarningKind {
  backupMissing,
  backupStale,
  backupFailed,
  restorePointMissing,
  coveragePartial,
  storagePressure,
}

enum CoreProxmoxRetentionSeverity { attention, critical }

final class CoreProxmoxRetentionWarning {
  const CoreProxmoxRetentionWarning._({
    required this.kind,
    required this.severity,
    required this.affectedCount,
    required this.observedPercent,
    required this.age,
  });

  final CoreProxmoxRetentionWarningKind kind;
  final CoreProxmoxRetentionSeverity severity;
  final int affectedCount;
  final int? observedPercent;
  final Duration? age;

  factory CoreProxmoxRetentionWarning.fromJson(Object? raw) {
    final value = _object(raw, {
      'kind',
      'severity',
      'affectedCount',
      'observedPercent',
      'ageSeconds',
    });
    final kind = switch (value['kind']) {
      'backup_missing' => CoreProxmoxRetentionWarningKind.backupMissing,
      'backup_stale' => CoreProxmoxRetentionWarningKind.backupStale,
      'backup_failed' => CoreProxmoxRetentionWarningKind.backupFailed,
      'restore_point_missing' =>
        CoreProxmoxRetentionWarningKind.restorePointMissing,
      'coverage_partial' => CoreProxmoxRetentionWarningKind.coveragePartial,
      'storage_pressure' => CoreProxmoxRetentionWarningKind.storagePressure,
      _ => _invalid(),
    };
    final observed = value['observedPercent'] == null
        ? null
        : _integer(value['observedPercent'], max: 100);
    final age = value['ageSeconds'] == null
        ? null
        : Duration(seconds: _integer(value['ageSeconds']));
    if ((kind == CoreProxmoxRetentionWarningKind.storagePressure) !=
            (observed != null) ||
        (kind == CoreProxmoxRetentionWarningKind.backupStale) !=
            (age != null)) {
      _invalid();
    }
    return CoreProxmoxRetentionWarning._(
      kind: kind,
      severity: switch (value['severity']) {
        'attention' => CoreProxmoxRetentionSeverity.attention,
        'critical' => CoreProxmoxRetentionSeverity.critical,
        _ => _invalid(),
      },
      affectedCount: _integer(value['affectedCount'], min: 1, max: 256),
      observedPercent: observed,
      age: age,
    );
  }
}

final class CoreProxmoxRetentionSummary {
  const CoreProxmoxRetentionSummary._({
    required this.state,
    required this.latestSuccessfulBackupAt,
    required this.latestSuccessfulBackupAge,
    required this.evaluatedGuestCount,
    required this.protectedGuestCount,
    required this.coverageTruncated,
    required this.highestStorageUsedPercent,
    required this.warnings,
  });

  final CoreProxmoxRetentionState state;
  final DateTime? latestSuccessfulBackupAt;
  final Duration? latestSuccessfulBackupAge;
  final int evaluatedGuestCount, protectedGuestCount;
  final bool coverageTruncated;
  final int? highestStorageUsedPercent;
  final List<CoreProxmoxRetentionWarning> warnings;

  factory CoreProxmoxRetentionSummary.fromJson(Object? raw) {
    final value = _object(raw, {
      'state',
      'latestSuccessfulBackupAt',
      'latestSuccessfulBackupAgeSeconds',
      'evaluatedGuestCount',
      'protectedGuestCount',
      'coverageTruncated',
      'highestStorageUsedPercent',
      'warnings',
    });
    final latest = value['latestSuccessfulBackupAt'] == null
        ? null
        : _timestamp(value['latestSuccessfulBackupAt']);
    final ageSeconds = value['latestSuccessfulBackupAgeSeconds'] == null
        ? null
        : _integer(value['latestSuccessfulBackupAgeSeconds']);
    final source = value['warnings'];
    if (source is! List ||
        source.length > 6 ||
        value['coverageTruncated'] is! bool ||
        (latest == null) != (ageSeconds == null)) {
      _invalid();
    }
    final evaluated = _integer(value['evaluatedGuestCount'], max: 8);
    final protected = _integer(value['protectedGuestCount'], max: 8);
    final warnings = List<CoreProxmoxRetentionWarning>.unmodifiable(
      source.map(CoreProxmoxRetentionWarning.fromJson),
    );
    if (protected > evaluated ||
        warnings.map((warning) => warning.kind).toSet().length !=
            warnings.length) {
      _invalid();
    }
    final state = switch (value['state']) {
      'healthy' => CoreProxmoxRetentionState.healthy,
      'attention' => CoreProxmoxRetentionState.attention,
      'critical' => CoreProxmoxRetentionState.critical,
      _ => _invalid(),
    };
    final expected = warnings.isEmpty
        ? CoreProxmoxRetentionState.healthy
        : warnings.any(
            (warning) =>
                warning.severity == CoreProxmoxRetentionSeverity.critical,
          )
        ? CoreProxmoxRetentionState.critical
        : CoreProxmoxRetentionState.attention;
    if (state != expected) _invalid();
    return CoreProxmoxRetentionSummary._(
      state: state,
      latestSuccessfulBackupAt: latest,
      latestSuccessfulBackupAge: ageSeconds == null
          ? null
          : Duration(seconds: ageSeconds),
      evaluatedGuestCount: evaluated,
      protectedGuestCount: protected,
      coverageTruncated: value['coverageTruncated'] as bool,
      highestStorageUsedPercent: value['highestStorageUsedPercent'] == null
          ? null
          : _integer(value['highestStorageUsedPercent'], max: 100),
      warnings: warnings,
    );
  }
}

enum CoreProxmoxMaintenanceState { healthy, attention, critical }

enum CoreProxmoxWarningSeverity { warning, critical }

enum CoreProxmoxWarningKind {
  nodeOffline,
  storageOffline,
  nodeCpuPressure,
  nodeMemoryPressure,
  storagePressure,
  recentTaskFailed,
}

final class CoreProxmoxMaintenanceWarning {
  const CoreProxmoxMaintenanceWarning._({
    required this.id,
    required this.kind,
    required this.severity,
    required this.node,
    required this.storage,
    required this.observedPercent,
    required this.thresholdPercent,
    required this.relatedTaskId,
  });

  final String id, node;
  final CoreProxmoxWarningKind kind;
  final CoreProxmoxWarningSeverity severity;
  final String? storage, relatedTaskId;
  final int? observedPercent, thresholdPercent;

  factory CoreProxmoxMaintenanceWarning.fromJson(Object? raw) {
    final value = _object(raw, {
      'warningId',
      'kind',
      'severity',
      'node',
      'storage',
      'observedPercent',
      'thresholdPercent',
      'relatedTaskId',
    });
    final kind = switch (value['kind']) {
      'node_offline' => CoreProxmoxWarningKind.nodeOffline,
      'storage_offline' => CoreProxmoxWarningKind.storageOffline,
      'node_cpu_pressure' => CoreProxmoxWarningKind.nodeCpuPressure,
      'node_memory_pressure' => CoreProxmoxWarningKind.nodeMemoryPressure,
      'storage_pressure' => CoreProxmoxWarningKind.storagePressure,
      'recent_task_failed' => CoreProxmoxWarningKind.recentTaskFailed,
      _ => _invalid(),
    };
    final severity = switch (value['severity']) {
      'warning' => CoreProxmoxWarningSeverity.warning,
      'critical' => CoreProxmoxWarningSeverity.critical,
      _ => _invalid(),
    };
    int? optionalPercent(String key) {
      final raw = value[key];
      return raw == null ? null : _integer(raw, max: 100);
    }

    final storage = value['storage'] == null
        ? null
        : _safe(
            value['storage'],
            max: 64,
            pattern: r'^[A-Za-z0-9][A-Za-z0-9._-]*$',
          );
    final observed = optionalPercent('observedPercent');
    final threshold = optionalPercent('thresholdPercent');
    final task = value['relatedTaskId'] == null
        ? null
        : _digest(value['relatedTaskId']);
    final pressure = {
      CoreProxmoxWarningKind.nodeCpuPressure,
      CoreProxmoxWarningKind.nodeMemoryPressure,
      CoreProxmoxWarningKind.storagePressure,
    }.contains(kind);
    final storageKind = {
      CoreProxmoxWarningKind.storageOffline,
      CoreProxmoxWarningKind.storagePressure,
    }.contains(kind);
    if (storageKind != (storage != null) ||
        (kind == CoreProxmoxWarningKind.recentTaskFailed) != (task != null) ||
        pressure != (observed != null && threshold != null)) {
      _invalid();
    }
    if (pressure) {
      final low = kind == CoreProxmoxWarningKind.nodeCpuPressure ? 75 : 80;
      final expected = severity == CoreProxmoxWarningSeverity.critical
          ? 90
          : low;
      if (threshold != expected ||
          observed! < expected ||
          severity == CoreProxmoxWarningSeverity.warning && observed >= 90) {
        _invalid();
      }
    } else if (kind == CoreProxmoxWarningKind.recentTaskFailed
        ? severity != CoreProxmoxWarningSeverity.warning
        : severity != CoreProxmoxWarningSeverity.critical) {
      _invalid();
    }
    return CoreProxmoxMaintenanceWarning._(
      id: _digest(value['warningId']),
      kind: kind,
      severity: severity,
      node: _safe(
        value['node'],
        max: 64,
        pattern: r'^[A-Za-z0-9][A-Za-z0-9._-]*$',
      ),
      storage: storage,
      observedPercent: observed,
      thresholdPercent: threshold,
      relatedTaskId: task,
    );
  }
}

final class CoreProxmoxMaintenanceSummary {
  const CoreProxmoxMaintenanceSummary._({
    required this.state,
    required this.warningCount,
    required this.truncated,
    required this.warnings,
  });

  final CoreProxmoxMaintenanceState state;
  final int warningCount;
  final bool truncated;
  final List<CoreProxmoxMaintenanceWarning> warnings;

  factory CoreProxmoxMaintenanceSummary.fromJson(Object? raw) {
    final value = _object(raw, {
      'state',
      'warningCount',
      'truncated',
      'warnings',
    });
    final source = value['warnings'];
    if (source is! List || source.length > 32 || value['truncated'] is! bool) {
      _invalid();
    }
    final warnings = List<CoreProxmoxMaintenanceWarning>.unmodifiable(
      source.map(CoreProxmoxMaintenanceWarning.fromJson),
    );
    final count = _integer(value['warningCount'], max: 148);
    final truncated = value['truncated'] as bool;
    if (truncated != (count > warnings.length) ||
        !truncated && count != warnings.length ||
        warnings.map((warning) => warning.id).toSet().length !=
            warnings.length) {
      _invalid();
    }
    final hasCritical = warnings.any(
      (warning) => warning.severity == CoreProxmoxWarningSeverity.critical,
    );
    final state = switch (value['state']) {
      'healthy' => CoreProxmoxMaintenanceState.healthy,
      'attention' => CoreProxmoxMaintenanceState.attention,
      'critical' => CoreProxmoxMaintenanceState.critical,
      _ => _invalid(),
    };
    final expected = count == 0
        ? CoreProxmoxMaintenanceState.healthy
        : hasCritical
        ? CoreProxmoxMaintenanceState.critical
        : CoreProxmoxMaintenanceState.attention;
    if (state != expected) _invalid();
    return CoreProxmoxMaintenanceSummary._(
      state: state,
      warningCount: count,
      truncated: truncated,
      warnings: warnings,
    );
  }
}

final class CoreProxmoxSummary {
  const CoreProxmoxSummary._(
    this.nodes,
    this.guests,
    this.storages,
    this.recentTasks,
    this.maintenance,
    this.protection,
    this.retention,
  );
  final List<CoreProxmoxNode> nodes;
  final List<CoreProxmoxGuest> guests;
  final List<CoreProxmoxStorage> storages;
  final List<CoreProxmoxRecentTask> recentTasks;
  final CoreProxmoxMaintenanceSummary maintenance;
  final CoreProxmoxProtectionSummary protection;
  final CoreProxmoxRetentionSummary retention;

  factory CoreProxmoxSummary.fromJson(Object? raw) {
    final value = _object(raw, {
      'nodes',
      'guests',
      'storages',
      'recentTasks',
      'maintenance',
      'protection',
      'retention',
    });
    List<T> list<T>(String key, int max, T Function(Object?) parse) {
      final source = value[key];
      if (source is! List || source.length > max) _invalid();
      return List<T>.unmodifiable(source.map(parse));
    }

    final nodes = list('nodes', 32, CoreProxmoxNode.fromJson),
        guests = list('guests', 256, CoreProxmoxGuest.fromJson),
        storages = list('storages', 64, CoreProxmoxStorage.fromJson),
        recentTasks = list('recentTasks', 20, CoreProxmoxRecentTask.fromJson);
    if (nodes.map((e) => e.name).toSet().length != nodes.length ||
        guests.map((e) => '${e.kind.name}:${e.vmId}').toSet().length !=
            guests.length ||
        storages.map((e) => '${e.node}:${e.name}').toSet().length !=
            storages.length ||
        recentTasks.map((e) => e.id).toSet().length != recentTasks.length) {
      _invalid();
    }
    final maintenance = CoreProxmoxMaintenanceSummary.fromJson(
      value['maintenance'],
    );
    final protection = CoreProxmoxProtectionSummary.fromJson(
      value['protection'],
    );
    final retention = CoreProxmoxRetentionSummary.fromJson(value['retention']);
    final nodeNames = nodes.map((node) => node.name).toSet();
    final storageNames = storages
        .map((storage) => '${storage.node}:${storage.name}')
        .toSet();
    final failedTasks = {
      for (final task in recentTasks)
        if (task.status == CoreProxmoxTaskStatus.failed) task.id: task.node,
    };
    final semanticWarnings = <String>{};
    for (final warning in maintenance.warnings) {
      final semantic =
          '${warning.kind.name}:${warning.node}:'
          '${warning.storage ?? ''}:${warning.relatedTaskId ?? ''}';
      if (!nodeNames.contains(warning.node) ||
          warning.storage != null &&
              !storageNames.contains('${warning.node}:${warning.storage}') ||
          warning.relatedTaskId != null &&
              failedTasks[warning.relatedTaskId] != warning.node ||
          !semanticWarnings.add(semantic)) {
        _invalid();
      }
    }
    final guestKeys = guests
        .map((guest) => '${guest.node}:${guest.kind.name}:${guest.vmId}')
        .toSet();
    if (protection.snapshots.any(
      (item) =>
          !guestKeys.contains('${item.node}:${item.kind.name}:${item.vmId}'),
    )) {
      _invalid();
    }
    final backup = protection.latestBackup;
    if (backup != null &&
        !recentTasks.any(
          (task) =>
              task.id == backup.id &&
              task.node == backup.node &&
              task.kind == backup.kind &&
              task.status == backup.status &&
              task.startedAt == backup.startedAt &&
              task.finishedAt == backup.finishedAt,
        )) {
      _invalid();
    }
    final activePercentages = storages
        .where((storage) => storage.active)
        .map(
          (storage) =>
              (storage.usedBytes * 100 + storage.totalBytes ~/ 2) ~/
              storage.totalBytes,
        )
        .toList(growable: false);
    final highest = activePercentages.isEmpty
        ? null
        : activePercentages.reduce((a, b) => a > b ? a : b);
    final successful = recentTasks
        .where(
          (task) =>
              task.kind == 'vzdump' &&
              task.status == CoreProxmoxTaskStatus.succeeded,
        )
        .toList(growable: false);
    successful.sort((a, b) => a.finishedAt!.compareTo(b.finishedAt!));
    final latestSuccess = successful.lastOrNull;
    if (retention.evaluatedGuestCount != protection.scannedGuestCount ||
        retention.protectedGuestCount !=
            protection.snapshots
                .where((item) => item.snapshotCount > 0)
                .length ||
        retention.coverageTruncated != protection.truncated ||
        retention.highestStorageUsedPercent != highest ||
        retention.latestSuccessfulBackupAt != latestSuccess?.finishedAt) {
      _invalid();
    }
    final expectedWarnings =
        <
          (
            CoreProxmoxRetentionWarningKind,
            CoreProxmoxRetentionSeverity,
            int,
            int?,
            Duration?,
          )
        >[];
    final age = retention.latestSuccessfulBackupAge;
    if (latestSuccess == null) {
      expectedWarnings.add((
        CoreProxmoxRetentionWarningKind.backupMissing,
        CoreProxmoxRetentionSeverity.critical,
        1,
        null,
        null,
      ));
    } else if (age!.inSeconds >= 86400) {
      expectedWarnings.add((
        CoreProxmoxRetentionWarningKind.backupStale,
        age.inSeconds >= 259200
            ? CoreProxmoxRetentionSeverity.critical
            : CoreProxmoxRetentionSeverity.attention,
        1,
        null,
        age,
      ));
    }
    final failed = recentTasks
        .where(
          (task) =>
              task.kind == 'vzdump' &&
              task.status == CoreProxmoxTaskStatus.failed,
        )
        .length;
    if (failed > 0) {
      expectedWarnings.add((
        CoreProxmoxRetentionWarningKind.backupFailed,
        CoreProxmoxRetentionSeverity.critical,
        failed,
        null,
        null,
      ));
    }
    final missing =
        retention.evaluatedGuestCount - retention.protectedGuestCount;
    if (missing > 0) {
      expectedWarnings.add((
        CoreProxmoxRetentionWarningKind.restorePointMissing,
        CoreProxmoxRetentionSeverity.attention,
        missing,
        null,
        null,
      ));
    }
    final unseen = protection.guestCount - retention.evaluatedGuestCount;
    if (unseen > 0) {
      expectedWarnings.add((
        CoreProxmoxRetentionWarningKind.coveragePartial,
        CoreProxmoxRetentionSeverity.attention,
        unseen,
        null,
        null,
      ));
    }
    final pressured = activePercentages.where((value) => value >= 80).toList();
    if (pressured.isNotEmpty) {
      final observed = pressured.reduce((a, b) => a > b ? a : b);
      expectedWarnings.add((
        CoreProxmoxRetentionWarningKind.storagePressure,
        observed >= 90
            ? CoreProxmoxRetentionSeverity.critical
            : CoreProxmoxRetentionSeverity.attention,
        pressured.length,
        observed,
        null,
      ));
    }
    final actualWarnings = retention.warnings
        .map(
          (warning) => (
            warning.kind,
            warning.severity,
            warning.affectedCount,
            warning.observedPercent,
            warning.age,
          ),
        )
        .toList(growable: false);
    if (actualWarnings.length != expectedWarnings.length ||
        List.generate(
          actualWarnings.length,
          (index) => actualWarnings[index] == expectedWarnings[index],
        ).contains(false)) {
      _invalid();
    }
    return CoreProxmoxSummary._(
      nodes,
      guests,
      storages,
      recentTasks,
      maintenance,
      protection,
      retention,
    );
  }
}

final class CoreProxmoxBinding {
  const CoreProxmoxBinding._({
    required this.id,
    required this.revision,
    required this.target,
    required this.serviceId,
    required this.serviceRevision,
  });
  final String id, serviceId;
  final int revision, serviceRevision;
  final HomeResourceRecord target;

  factory CoreProxmoxBinding.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'id',
      'revision',
      'ref',
      'serviceId',
      'serviceRevision',
    });
    if (value['schemaVersion'] != 1) _invalid();
    _ref(value['ref'], target);
    return CoreProxmoxBinding._(
      id: _id(value['id']),
      revision: _integer(value['revision'], min: 1),
      target: target,
      serviceId: _id(value['serviceId']),
      serviceRevision: _integer(value['serviceRevision'], min: 1),
    );
  }

  bool sameBinding(CoreProxmoxBinding other) =>
      id == other.id &&
      revision == other.revision &&
      target.id == other.target.id &&
      target.context == other.target.context &&
      serviceId == other.serviceId &&
      serviceRevision == other.serviceRevision;
}

final class CoreProxmoxPreview {
  const CoreProxmoxPreview._(
    this.id,
    this.expiresInMs,
    this.binding,
    this.summary,
  );
  final String id;
  final int expiresInMs;
  final CoreProxmoxBinding binding;
  final CoreProxmoxSummary summary;

  factory CoreProxmoxPreview.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {'id', 'expiresInMs', 'binding', 'summary'});
    return CoreProxmoxPreview._(
      _id(value['id']),
      _integer(value['expiresInMs'], min: 1, max: 60000),
      CoreProxmoxBinding.fromJson(value['binding'], target: target),
      CoreProxmoxSummary.fromJson(value['summary']),
    );
  }
}

final class CoreProxmoxSnapshot {
  const CoreProxmoxSnapshot._({
    required this.bindingId,
    required this.bindingRevision,
    required this.resourceRevision,
    required this.aclRevision,
    required this.serviceId,
    required this.serviceRevision,
    required this.observedAt,
    required this.remainingTtlMs,
    required this.summary,
  });
  final String bindingId, serviceId;
  final int bindingRevision,
      resourceRevision,
      aclRevision,
      serviceRevision,
      remainingTtlMs;
  final DateTime observedAt;
  final CoreProxmoxSummary summary;
  Duration get remainingTtl => Duration(milliseconds: remainingTtlMs);

  factory CoreProxmoxSnapshot.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'ref',
      'bindingId',
      'bindingRevision',
      'resourceRevision',
      'aclRevision',
      'serviceId',
      'serviceRevision',
      'observedAt',
      'remainingTtlMs',
      'summary',
    });
    if (value['schemaVersion'] != 1) _invalid();
    _ref(value['ref'], target);
    final resourceRevision = _integer(value['resourceRevision'], min: 1),
        aclRevision = _integer(value['aclRevision'], min: 1);
    if (resourceRevision != target.revision ||
        aclRevision != target.aclRevision) {
      _invalid();
    }
    return CoreProxmoxSnapshot._(
      bindingId: _id(value['bindingId']),
      bindingRevision: _integer(value['bindingRevision'], min: 1),
      resourceRevision: resourceRevision,
      aclRevision: aclRevision,
      serviceId: _id(value['serviceId']),
      serviceRevision: _integer(value['serviceRevision'], min: 1),
      observedAt: _timestamp(value['observedAt']),
      remainingTtlMs: _integer(value['remainingTtlMs'], max: 5000),
      summary: CoreProxmoxSummary.fromJson(value['summary']),
    );
  }

  @override
  String toString() => 'CoreProxmoxSnapshot';
}
