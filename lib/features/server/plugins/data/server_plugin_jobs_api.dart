import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_plugin_job_models.dart';

class ServerPluginJobPage {
  const ServerPluginJobPage(this.jobs, this.nextBefore);
  final List<ServerPluginJob> jobs;
  final int? nextBefore;
}

class ServerPluginJobEventPage {
  const ServerPluginJobEventPage(this.events, this.nextAfter);
  final List<ServerPluginJobEvent> events;
  final int? nextAfter;
}

/// Durable inspection only. No install, image pull or execution endpoint.
class ServerPluginJobsApi {
  const ServerPluginJobsApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;
  static const _root = '/admin/plugins/jobs';
  static const pageSize = 25;
  Never _invalid() => throw const LarenorServerException('invalid_response');
  Map<String, dynamic> _envelope(
    Map<String, dynamic>? value,
    Set<String> keys,
  ) {
    if (value == null ||
        value.length != keys.length ||
        !value.keys.every(keys.contains)) {
      _invalid();
    }
    return value;
  }

  Future<ServerPluginJobCapabilities> capabilities() async =>
      ServerPluginJobCapabilities.fromJson(
        await api.request('GET', '$_root/capabilities', token: token),
      );
  Future<ServerPluginJob> create(ServerPluginJobRequest request) async {
    final json = _envelope(
      await api.request('POST', _root, token: token, body: request.toJson()),
      {'job'},
    );
    final job = ServerPluginJob.fromJson(json['job']);
    if (!request.accepts(job)) _invalid();
    return job;
  }

  Future<ServerPluginJob> get(String id, {ServerPluginJob? previous}) async {
    pluginJobId(id);
    final json = _envelope(
      await api.request('GET', '$_root/$id', token: token),
      {'job'},
    );
    final job = ServerPluginJob.fromJson(json['job']);
    if (job.id != id ||
        (previous != null &&
            (!previous.sameIdentity(job) ||
                job.revision < previous.revision ||
                job.updatedAt.isBefore(previous.updatedAt)))) {
      _invalid();
    }
    return job;
  }

  Future<ServerPluginJobPage> list({int? before}) async {
    if (before != null) pluginJobInteger(before);
    final json = _envelope(
      await api.request(
        'GET',
        _root,
        token: token,
        queryParameters: {
          'limit': '$pageSize',
          if (before != null) 'before': '$before',
        },
      ),
      {'jobs', 'nextBefore'},
    );
    final values = json['jobs'];
    if (values is! List || values.length > pageSize) _invalid();
    final jobs = values.map(ServerPluginJob.fromJson).toList();
    final next = json['nextBefore'] == null
        ? null
        : pluginJobInteger(json['nextBefore']);
    if (jobs.map((j) => j.id).toSet().length != jobs.length ||
        (next != null &&
            (jobs.isEmpty || (before != null && next >= before)))) {
      _invalid();
    }
    return ServerPluginJobPage(List.unmodifiable(jobs), next);
  }

  Future<ServerPluginJobEventPage> events(String id, {int after = 0}) async {
    pluginJobId(id);
    pluginJobInteger(after, minimum: 0);
    final json = _envelope(
      await api.request(
        'GET',
        '$_root/$id/events',
        token: token,
        queryParameters: {'after': '$after', 'limit': '$pageSize'},
      ),
      {'events', 'nextAfter'},
    );
    final values = json['events'];
    if (values is! List || values.length > pageSize) _invalid();
    final events = values.map(ServerPluginJobEvent.fromJson).toList();
    var sequence = after, revision = 0;
    for (final event in events) {
      if (event.sequence <= sequence || event.jobRevision < revision) {
        _invalid();
      }
      sequence = event.sequence;
      revision = event.jobRevision;
    }
    final next = json['nextAfter'] == null
        ? null
        : pluginJobInteger(json['nextAfter']);
    if (next != null && (events.isEmpty || next != sequence)) _invalid();
    return ServerPluginJobEventPage(List.unmodifiable(events), next);
  }

  Future<ServerPluginJob> cancel(ServerPluginJob previous) async {
    final json = _envelope(
      await api.request(
        'POST',
        '$_root/${previous.id}/cancel',
        token: token,
        body: {'expectedRevision': previous.revision},
      ),
      {'job'},
    );
    final job = ServerPluginJob.fromJson(json['job']);
    if (!previous.sameIdentity(job) ||
        job.revision < previous.revision ||
        job.updatedAt.isBefore(previous.updatedAt)) {
      _invalid();
    }
    return job;
  }

  @override
  String toString() => 'ServerPluginJobsApi';
}
