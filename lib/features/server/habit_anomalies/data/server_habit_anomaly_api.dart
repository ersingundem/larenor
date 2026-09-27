import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../../services/data/server_services_api.dart';
import '../../services/domain/server_service_models.dart';
import '../domain/server_habit_anomaly_models.dart';

final class ServerHabitAnomalyApi {
  const ServerHabitAnomalyApi(this.api, this.token, this.context);

  final LarenorServerApi api;
  final String token;
  final ServerContext context;
  String get _root => '/habit-anomalies/${context.coreId}/${context.homeId}';

  Future<HabitAnomalyReport?> snapshot() async {
    final json = serverObject(await api.request('GET', _root, token: token));
    if (json.length != 3 ||
        !json.keys.toSet().containsAll({'schemaVersion', 'scope', 'reports'}) ||
        json['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final reports = json['reports'];
    if (reports is! List || reports.length > 64) {
      throw const LarenorServerException('invalid_response');
    }
    final parsed = reports
        .map(HabitAnomalyReport.fromJson)
        .where((report) => report.seriesId == 'service_unavailable_count');
    return parsed.firstOrNull;
  }

  Future<HabitAnomalyReport> observeServices(String requestKey) async {
    final services = (await ServerServicesApi(api, token).list()).take(32);
    if (services.isEmpty) {
      throw const LarenorServerException('habit_services_empty');
    }
    final checked = <ServerService>[];
    for (final service in services) {
      checked.add(await ServerServicesApi(api, token).check(service));
    }
    final times = checked
        .map((service) => service.verification.checkedAt)
        .whereType<DateTime>()
        .toList();
    if (times.length != checked.length) {
      throw const LarenorServerException('invalid_response');
    }
    final unavailable = checked.where((service) {
      return switch (service.verification.state) {
        ServerServiceVerificationState.authenticated ||
        ServerServiceVerificationState.reachable => false,
        _ => true,
      };
    }).length;
    final observedAt = times.reduce((a, b) => a.isAfter(b) ? a : b);
    final json = serverObject(
      await api.request(
        'POST',
        '$_root/observations',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestKey': requestKey,
          'seriesId': 'service_unavailable_count',
          'metric': 'service_unavailable_count',
          'unit': 'count',
          'value': unavailable,
          'observedAtMs': observedAt.millisecondsSinceEpoch,
        },
      ),
    );
    return _report(json);
  }

  Future<HabitAnomalyReport> mark(
    HabitAnomalyReport report,
    String label,
    String requestKey,
  ) async {
    final id = report.current.observationId;
    final json = serverObject(
      await api.request(
        'POST',
        '$_root/observations/$id/feedback',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestKey': requestKey,
          'expectedObservationId': id,
          'label': label,
        },
      ),
    );
    return _report(json);
  }

  static HabitAnomalyReport _report(Map<String, dynamic> json) {
    if (json.length != 1 || !json.containsKey('report')) {
      throw const LarenorServerException('invalid_response');
    }
    return HabitAnomalyReport.fromJson(json['report']);
  }

  static String requestKey(String prefix) {
    final random = Random.secure();
    final value = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '$prefix:$value';
  }
}
