import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_ai_memory_models.dart';

final class ServerAiMemoryApi {
  const ServerAiMemoryApi(this.api, this.token, this.context, this.accountId);

  final LarenorServerApi api;
  final String token, accountId;
  final ServerContext context;
  String get _root => '/ai-memory/${context.coreId}/${context.homeId}';

  Future<AiMemorySnapshot> snapshot() =>
      _snapshot(api.request('GET', _root, token: token));

  Future<AiMemoryRecord> remember({
    required String requestKey,
    required String content,
    required int durationSeconds,
  }) => _record(
    api.request(
      'POST',
      '$_root/memories',
      token: token,
      body: {
        'schemaVersion': 1,
        'requestKey': requestKey,
        'source': {
          'schemaVersion': 1,
          'kind': 'manual',
          'description': 'Larenor memory manager',
        },
        'content': content,
        'durationSeconds': durationSeconds,
      },
    ),
  );

  Future<AiMemoryRecord> correct(
    AiMemoryRecord memory, {
    required String requestKey,
    required String content,
    required int durationSeconds,
  }) => _record(
    api.request(
      'PUT',
      '$_root/memories/${memory.id}',
      token: token,
      body: {
        'schemaVersion': 1,
        'requestKey': requestKey,
        'expectedRevision': memory.revision,
        'source': {
          'schemaVersion': 1,
          'kind': 'manual',
          'description': 'Larenor memory manager',
        },
        'content': content,
        'durationSeconds': durationSeconds,
      },
    ),
  );

  Future<void> forget(AiMemoryRecord memory, String requestKey) async {
    final json = serverObject(
      await api.request(
        'POST',
        '$_root/memories/${memory.id}/forget',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestKey': requestKey,
          'expectedRevision': memory.revision,
          'reason': 'userRequested',
        },
      ),
    );
    if (json.length != 1 || !json.containsKey('tombstone')) {
      throw const LarenorServerException('invalid_response');
    }
    final tombstone = serverObject(json['tombstone']);
    if (tombstone['memoryId'] != memory.id ||
        tombstone['deletedRevision'] != memory.revision + 1) {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<AiMemorySnapshot> _snapshot(Future<Object?> pending) async {
    final value = AiMemorySnapshot.fromJson(await pending);
    if (value.context != context || value.accountId != accountId) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  Future<AiMemoryRecord> _record(Future<Object?> pending) async {
    final json = serverObject(await pending);
    if (json.length != 1 || !json.containsKey('memory')) {
      throw const LarenorServerException('invalid_response');
    }
    return AiMemoryRecord.fromJson(json['memory']);
  }
}
