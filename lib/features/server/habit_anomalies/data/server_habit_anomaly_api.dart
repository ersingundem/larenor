import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
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
    return reports.map(HabitAnomalyReport.fromJson).firstOrNull;
  }

  Future<HabitAnomalyReport> observeServices(String requestKey) async {
    final sourceResourceId = await _historySource();
    if (sourceResourceId == null) {
      throw const LarenorServerException('habit_services_empty');
    }
    final json = serverObject(
      await api.request(
        'POST',
        '$_root/home-assistant-history',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestKey': requestKey,
          'sourceResourceId': sourceResourceId,
        },
      ),
    );
    return _report(json);
  }

  Future<String?> _historySource() async {
    final listed = serverObject(
      await api.request(
        'GET',
        '/home-resources/${context.coreId}/${context.homeId}',
        token: token,
        queryParameters: const {'limit': '100'},
      ),
    );
    final entries = listed['entries'];
    if (entries is! List || entries.length > 100) {
      throw const LarenorServerException('invalid_response');
    }
    for (final raw in entries) {
      final entry = serverObject(raw);
      final ref = serverObject(entry['ref']);
      if (ref['kind'] != 'resource') continue;
      final resourceId = serverText(ref['id'], max: 32);
      try {
        final response = serverObject(
          await api.request(
            'GET',
            '/admin/home-assistant/${context.coreId}/${context.homeId}'
                '/resources/$resourceId/binding',
            token: token,
          ),
        );
        final binding = serverObject(response['binding']);
        serverText(binding['entityId'], max: 256);
        return resourceId;
      } on LarenorServerException catch (error) {
        if (error.code != 'not_found') rethrow;
      }
    }
    return null;
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
