import 'dart:math';

import '../../../today/data/today_timezone.dart';
import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
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
    final source = await _automationSource();
    if (source == null) {
      throw const LarenorServerException('trial_services_empty');
    }
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
              'ruleId': source.bindingId,
              'eventKey': 'automation_triggered',
              'deviceId': source.resourceId,
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
    if (source == 'real') {
      final json = serverObject(
        await api.request(
          'POST',
          '$_root/${trial.id}/home-assistant-traces',
          token: token,
          body: {
            'schemaVersion': 1,
            'requestKey': requestKey('automation-trial-ha-trace'),
            'expectedTrialId': trial.id,
            'sourceResourceId': trial.ruleDeviceId,
          },
        ),
      );
      return _trial(json);
    }
    final occurredAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
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

  Future<_AutomationSource?> _automationSource() async {
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
        final entityId = serverText(binding['entityId'], max: 128);
        final bindingId = serverText(binding['id'], max: 32);
        if (entityId.startsWith('automation.')) {
          return _AutomationSource(resourceId, bindingId);
        }
      } on LarenorServerException catch (error) {
        if (error.code != 'not_found') rethrow;
      }
    }
    return null;
  }

  Future<AutomationTrialReplay> replay(AutomationTrial trial) async {
    final json = serverObject(
      await api.request(
        'POST',
        '$_root/${trial.id}/replays',
        token: token,
        body: {
          'schemaVersion': 1,
          'expectedTrialId': trial.id,
          'requiredEventCount': 1,
          'proposedRules': [
            for (final rule in trial.rules) rule.toJson(flipAction: true),
          ],
        },
      ),
    );
    if (json.length != 1 || !json.containsKey('replay')) {
      throw const LarenorServerException('invalid_response');
    }
    return AutomationTrialReplay.fromJson(json['replay']);
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

final class _AutomationSource {
  const _AutomationSource(this.resourceId, this.bindingId);
  final String resourceId, bindingId;
}
