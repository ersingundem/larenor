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
    return AiMemorySnapshot(
      ServerContext.fromJson(scope),
      serverText(scope['accountId'], max: 32),
      List.unmodifiable(memories),
    );
  }

  final ServerContext context;
  final String accountId;
  final List<AiMemoryRecord> memories;
}
