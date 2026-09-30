import '../../domain/server_models.dart';

Map<String, dynamic> _closed(Object? value, Set<String> keys) {
  final json = serverObject(value);
  if (json.length != keys.length || !json.keys.every(keys.contains)) {
    throw const LarenorServerException('invalid_response');
  }
  return json;
}

double _finite(Object? value) {
  if (value is! num || !value.isFinite || value < 0) {
    throw const LarenorServerException('invalid_response');
  }
  return value.toDouble();
}

final class AiMemorySource {
  const AiMemorySource(this.kind, this.description);

  factory AiMemorySource.fromJson(Object? value) {
    final json = _closed(value, const {'schemaVersion', 'kind', 'description'});
    final kind = json['kind'];
    if (json['schemaVersion'] != 1 ||
        !{'manual', 'assistant', 'automation', 'integration'}.contains(kind)) {
      throw const LarenorServerException('invalid_response');
    }
    return AiMemorySource(
      kind as String,
      serverText(json['description'], max: 160),
    );
  }

  final String kind, description;
}

final class AiMemoryRetention {
  const AiMemoryRetention(this.durationSeconds, this.expiresAt);

  factory AiMemoryRetention.fromJson(Object? value) {
    final json = _closed(value, const {
      'durationSeconds',
      'expiresAt',
      'explanation',
    });
    final duration = json['durationSeconds'];
    if (duration is! int ||
        duration < 0 ||
        duration > 31536000 ||
        json['explanation'] != 'timeBounded') {
      throw const LarenorServerException('invalid_response');
    }
    return AiMemoryRetention(duration, _finite(json['expiresAt']));
  }

  final int durationSeconds;
  final double expiresAt;
}

final class AiMemoryRecord {
  const AiMemoryRecord._({
    required this.id,
    required this.revision,
    required this.content,
    required this.source,
    required this.learnedBy,
    required this.createdAt,
    required this.updatedAt,
    required this.retention,
  });

  factory AiMemoryRecord.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'memoryId',
      'revision',
      'content',
      'source',
      'learnedBy',
      'createdAt',
      'updatedAt',
      'retention',
    });
    final id = json['memoryId'];
    final revision = json['revision'];
    if (json['schemaVersion'] != 1 ||
        id is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        revision is! int ||
        revision < 1) {
      throw const LarenorServerException('invalid_response');
    }
    final createdAt = _finite(json['createdAt']);
    final updatedAt = _finite(json['updatedAt']);
    if (updatedAt < createdAt) {
      throw const LarenorServerException('invalid_response');
    }
    return AiMemoryRecord._(
      id: id,
      revision: revision,
      content: serverText(json['content'], max: 2048),
      source: AiMemorySource.fromJson(json['source']),
      learnedBy: serverText(json['learnedBy'], max: 80),
      createdAt: createdAt,
      updatedAt: updatedAt,
      retention: AiMemoryRetention.fromJson(json['retention']),
    );
  }

  final String id, content, learnedBy;
  final int revision;
  final AiMemorySource source;
  final double createdAt, updatedAt;
  final AiMemoryRetention retention;
}

final class AiMemorySnapshot {
  const AiMemorySnapshot(this.context, this.accountId, this.memories);

  factory AiMemorySnapshot.fromJson(Object? value) {
    final json = _closed(value, const {'schemaVersion', 'scope', 'memories'});
    final scope = _closed(json['scope'], const {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
    });
    final raw = json['memories'];
    if (json['schemaVersion'] != 1 ||
        scope['schemaVersion'] != 1 ||
        raw is! List ||
        raw.length > 1024) {
      throw const LarenorServerException('invalid_response');
    }
    final memories = raw.map(AiMemoryRecord.fromJson).toList();
    if (memories.map((item) => item.id).toSet().length != memories.length) {
      throw const LarenorServerException('invalid_response');
    }
    final accountId = scope['accountId'];
    if (accountId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(accountId)) {
      throw const LarenorServerException('invalid_response');
    }
    return AiMemorySnapshot(
      ServerContext.fromJson({
        'schemaVersion': scope['schemaVersion'],
        'coreId': scope['coreId'],
        'homeId': scope['homeId'],
      }),
      accountId,
      List.unmodifiable(memories),
    );
  }

  final ServerContext context;
  final String accountId;
  final List<AiMemoryRecord> memories;
}

final class AiMemoryBackupRecord {
  const AiMemoryBackupRecord._({
    required this.memoryId,
    required this.revision,
    required this.source,
    required this.content,
    required this.learnedBy,
    required this.createdAt,
    required this.updatedAt,
    required this.expiresAt,
  });

  factory AiMemoryBackupRecord.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'memoryId',
      'revision',
      'source',
      'content',
      'learnedBy',
      'createdAt',
      'updatedAt',
      'expiresAt',
    });
    final memoryId = json['memoryId'];
    final revision = json['revision'];
    if (json['schemaVersion'] != 1 ||
        memoryId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(memoryId) ||
        revision is! int ||
        revision < 1) {
      throw const LarenorServerException('invalid_response');
    }
    final createdAt = _finite(json['createdAt']);
    final updatedAt = _finite(json['updatedAt']);
    final expiresAt = _finite(json['expiresAt']);
    if (updatedAt < createdAt || expiresAt <= createdAt) {
      throw const LarenorServerException('invalid_response');
    }
    return AiMemoryBackupRecord._(
      memoryId: memoryId,
      revision: revision,
      source: AiMemorySource.fromJson(json['source']),
      content: serverText(json['content'], max: 2048),
      learnedBy: serverText(json['learnedBy'], max: 80),
      createdAt: createdAt,
      updatedAt: updatedAt,
      expiresAt: expiresAt,
    );
  }

  final String memoryId, content, learnedBy;
  final int revision;
  final AiMemorySource source;
  final double createdAt, updatedAt, expiresAt;

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'memoryId': memoryId,
    'revision': revision,
    'source': {
      'schemaVersion': 1,
      'kind': source.kind,
      'description': source.description,
    },
    'content': content,
    'learnedBy': learnedBy,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'expiresAt': expiresAt,
  };
}

final class AiMemoryBackupTombstone {
  const AiMemoryBackupTombstone._(
    this.memoryId,
    this.deletedRevision,
    this.deletedAt,
    this.reason,
  );

  factory AiMemoryBackupTombstone.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'memoryId',
      'deletedRevision',
      'deletedAt',
      'reason',
    });
    final memoryId = json['memoryId'];
    final revision = json['deletedRevision'];
    final reason = json['reason'];
    if (json['schemaVersion'] != 1 ||
        memoryId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(memoryId) ||
        revision is! int ||
        revision < 1 ||
        !{
          'userRequested',
          'privacy',
          'obsolete',
          'incorrect',
          'expired',
        }.contains(reason)) {
      throw const LarenorServerException('invalid_response');
    }
    return AiMemoryBackupTombstone._(
      memoryId,
      revision,
      _finite(json['deletedAt']),
      reason as String,
    );
  }

  final String memoryId, reason;
  final int deletedRevision;
  final double deletedAt;

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'memoryId': memoryId,
    'deletedRevision': deletedRevision,
    'deletedAt': deletedAt,
    'reason': reason,
  };
}

final class AiMemoryBackup {
  const AiMemoryBackup(this.records, this.tombstones);

  factory AiMemoryBackup.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'records',
      'tombstones',
    });
    final rawRecords = json['records'];
    final rawTombstones = json['tombstones'];
    if (json['schemaVersion'] != 1 ||
        rawRecords is! List ||
        rawRecords.length > 1024 ||
        rawTombstones is! List ||
        rawTombstones.length > 2048) {
      throw const LarenorServerException('invalid_response');
    }
    final records = rawRecords.map(AiMemoryBackupRecord.fromJson).toList();
    final tombstones = rawTombstones
        .map(AiMemoryBackupTombstone.fromJson)
        .toList();
    if (records.map((value) => value.memoryId).toSet().length !=
            records.length ||
        tombstones.map((value) => value.memoryId).toSet().length !=
            tombstones.length) {
      throw const LarenorServerException('invalid_response');
    }
    return AiMemoryBackup(
      List.unmodifiable(records),
      List.unmodifiable(tombstones),
    );
  }

  final List<AiMemoryBackupRecord> records;
  final List<AiMemoryBackupTombstone> tombstones;
}

final class AiMemoryRestoreResult {
  const AiMemoryRestoreResult(this.restoredCount, this.blockedCount);

  factory AiMemoryRestoreResult.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'restoredCount',
      'blockedCount',
    });
    final restored = json['restoredCount'];
    final blocked = json['blockedCount'];
    if (json['schemaVersion'] != 1 ||
        restored is! int ||
        restored < 0 ||
        restored > 1024 ||
        blocked is! int ||
        blocked < 0 ||
        blocked > 3072) {
      throw const LarenorServerException('invalid_response');
    }
    return AiMemoryRestoreResult(restored, blocked);
  }

  final int restoredCount, blockedCount;
}
