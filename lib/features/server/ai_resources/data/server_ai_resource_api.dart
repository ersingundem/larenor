import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_ai_resource_models.dart';

final class ServerAiResourceApi {
  const ServerAiResourceApi(this.api, this.token, this.context);

  final LarenorServerApi api;
  final String token;
  final ServerContext context;
  String get _root => '/ai-resources/${context.coreId}/${context.homeId}';

  Future<AiResourceSnapshot> snapshot() =>
      _read(api.request('GET', _root, token: token));

  Future<AiResourceSnapshot> updatePolicy(
    AiResourcePolicy current,
    AiResourcePreset preset,
  ) => _read(
    api.request(
      'PUT',
      '$_root/policy',
      token: token,
      body: {
        'schemaVersion': 1,
        'expectedRevision': current.revision,
        'maxMemoryMb': preset.memoryMb,
        'maxCpuPercent': preset.cpuPercent,
        'maxConcurrentJobs': preset.jobs,
        'mediaCpuPercent': preset.mediaCpuPercent,
      },
    ),
  );

  Future<AiResourceSnapshot> cancel(AiResourceJob job) => _read(
    api.request(
      'POST',
      '$_root/jobs/${job.id}/cancel',
      token: token,
      body: {'schemaVersion': 1, 'expectedRevision': job.revision},
    ),
  );

  Future<AiResourceSnapshot> _read(Future<Object?> result) async {
    final snapshot = AiResourceSnapshot.fromJson(await result);
    if (snapshot.context != context) {
      throw const LarenorServerException('invalid_response');
    }
    return snapshot;
  }
}
