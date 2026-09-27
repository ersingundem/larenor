import 'dart:math';

import '../../../today/data/today_timezone.dart';
import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../../services/data/server_services_api.dart';
import '../domain/server_automation_trial_models.dart';

final class ServerAutomationTrialApi {
  const ServerAutomationTrialApi(this.api, this.token, this.context);
  final LarenorServerApi api;
  final String token;
  final ServerContext context;
  String get _root => '/automation-trials/${context.coreId}/${context.homeId}';

  Future<AutomationTrial?> snapshot() async {
    final json = serverObject(await api.request('GET', _root, token: token));
    if (json.length != 3 ||
        json['schemaVersion'] != 1 ||
        json['trials'] is! List) {
      throw const LarenorServerException('invalid_response');
    }
    final trials = (json['trials'] as List)
        .map(AutomationTrial.fromJson)
        .toList();
    if (trials.length > 16) {
      throw const LarenorServerException('invalid_response');
    }
    return trials.firstOrNull;
  }

  Future<AutomationTrial> create(String timezone) async {
    final services = await ServerServicesApi(api, token).list();
    if (services.isEmpty) {
      throw const LarenorServerException('trial_services_empty');
    }
    final service = services.first;
    final DateTime local;
    try {
      local = TodayTimeZone(timezone).local(DateTime.now().toUtc());
    } catch (_) {
      throw const LarenorServerException('automation_trial_timezone_invalid');
    }
    final date =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    final json = serverObject(
      await api.request(
        'POST',
        _root,
        token: token,
        body: {
          'schemaVersion': 1,
          'requestKey': requestKey('automation-trial'),
          'timezone': timezone,
          'localStartDate': date,
          'rules': [
            {
              'ruleId': service.id,
              'eventKey': 'service_check',
              'deviceId': service.id,
              'action': 'turn_on',
              'priority': 50,
              'weekdays': [0, 1, 2, 3, 4, 5, 6],
              'startMinute': 0,
              'endMinute': 1440,
            },
          ],
        },
      ),
    );
    return _trial(json);
  }

  Future<AutomationTrial> evaluate(AutomationTrial trial, String source) async {
    int occurredAtMs;
    if (source == 'real') {
      final services = await ServerServicesApi(api, token).list();
      final service = services
          .where((item) => item.id == trial.ruleDeviceId)
          .firstOrNull;
      if (service == null) {
        throw const LarenorServerException('trial_service_missing');
      }
      final checked = await ServerServicesApi(api, token).check(service);
      final at = checked.verification.checkedAt;
      if (at == null) throw const LarenorServerException('invalid_response');
      occurredAtMs = at.millisecondsSinceEpoch;
    } else {
      occurredAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    }
    final json = serverObject(
      await api.request(
        'POST',
        '$_root/${trial.id}/events',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestKey': requestKey('automation-trial-event'),
          'source': source,
          'eventKey': 'service_check',
          'occurredAtMs': occurredAtMs,
        },
      ),
    );
    return _trial(json);
  }

  static AutomationTrial _trial(Map<String, dynamic> json) {
    if (json.length != 1 || !json.containsKey('trial')) {
      throw const LarenorServerException('invalid_response');
    }
    return AutomationTrial.fromJson(json['trial']);
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
