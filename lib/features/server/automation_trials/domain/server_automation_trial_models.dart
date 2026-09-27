import '../../domain/server_models.dart';

Map<String, dynamic> _closed(Object? value, Set<String> keys) {
  final json = serverObject(value);
  if (json.length != keys.length || !json.keys.every(keys.contains)) {
    throw const LarenorServerException('invalid_response');
  }
  return json;
}

List<Map<String, dynamic>> _objects(Object? value, {int max = 512}) {
  if (value is! List || value.length > max) {
    throw const LarenorServerException('invalid_response');
  }
  return value.map(serverObject).toList();
}

final class AutomationTrialDecision {
  const AutomationTrialDecision({
    required this.ruleId,
    required this.deviceId,
    required this.action,
    required this.priority,
    required this.state,
    required this.reason,
  });

  factory AutomationTrialDecision.fromJson(Object? value) {
    final json = _closed(value, const {
      'ruleId',
      'deviceId',
      'action',
      'priority',
      'state',
      'reason',
    });
    final priority = json['priority'];
    if (priority is! int ||
        priority < 0 ||
        priority > 100 ||
        !{'triggered', 'suppressed'}.contains(json['state'])) {
      throw const LarenorServerException('invalid_response');
    }
    return AutomationTrialDecision(
      ruleId: serverText(json['ruleId'], max: 32),
      deviceId: serverText(json['deviceId'], max: 32),
      action: serverText(json['action'], max: 32),
      priority: priority,
      state: json['state'] as String,
      reason: serverText(json['reason'], max: 64),
    );
  }

  final String ruleId, deviceId, action, state, reason;
  final int priority;
}

final class AutomationTrialEvent {
  const AutomationTrialEvent({
    required this.source,
    required this.eventKey,
    required this.occurredAtMs,
    required this.localDateTime,
    required this.utcOffsetSeconds,
    required this.fold,
    required this.decisions,
  });

  factory AutomationTrialEvent.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'source',
      'eventKey',
      'occurredAtMs',
      'localDateTime',
      'utcOffsetSeconds',
      'fold',
      'decisions',
      'adapterWriteCount',
    });
    final occurredAt = json['occurredAtMs'];
    final offset = json['utcOffsetSeconds'];
    final fold = json['fold'];
    if (json['schemaVersion'] != 1 ||
        !{'real', 'synthetic'}.contains(json['source']) ||
        occurredAt is! int ||
        occurredAt < 0 ||
        offset is! int ||
        fold is! int ||
        (fold != 0 && fold != 1) ||
        json['adapterWriteCount'] != 0) {
      throw const LarenorServerException('invalid_response');
    }
    return AutomationTrialEvent(
      source: json['source'] as String,
      eventKey: serverText(json['eventKey'], max: 64),
      occurredAtMs: occurredAt,
      localDateTime: serverText(json['localDateTime'], max: 64),
      utcOffsetSeconds: offset,
      fold: fold,
      decisions: List.unmodifiable(
        _objects(json['decisions']).map(AutomationTrialDecision.fromJson),
      ),
    );
  }

  final String source, eventKey, localDateTime;
  final int occurredAtMs, utcOffsetSeconds, fold;
  final List<AutomationTrialDecision> decisions;
}

final class AutomationTrial {
  const AutomationTrial({
    required this.id,
    required this.timezone,
    required this.localStartDate,
    required this.startsAtMs,
    required this.endsAtMs,
    required this.utcDurationSeconds,
    required this.ruleDeviceId,
    required this.eventCount,
    required this.triggeredCount,
    required this.suppressedCount,
    required this.events,
  });

  factory AutomationTrial.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'id',
      'timezone',
      'localStartDate',
      'startsAtMs',
      'endsAtMs',
      'utcDurationSeconds',
      'simulationOnly',
      'adapterWriteCount',
      'rules',
      'eventCount',
      'triggeredCount',
      'suppressedCount',
      'events',
    });
    final rules = _objects(json['rules'], max: 32);
    final events = _objects(json['events'])
        .map(AutomationTrialEvent.fromJson)
        .toList();
    final starts = json['startsAtMs'];
    final ends = json['endsAtMs'];
    final duration = json['utcDurationSeconds'];
    final eventCount = json['eventCount'];
    final triggered = json['triggeredCount'];
    final suppressed = json['suppressedCount'];
    if (json['schemaVersion'] != 1 ||
        json['simulationOnly'] != true ||
        json['adapterWriteCount'] != 0 ||
        rules.isEmpty ||
        starts is! int ||
        ends is! int ||
        ends <= starts ||
        duration is! int ||
        duration <= 0 ||
        eventCount is! int ||
        eventCount != events.length ||
        triggered is! int ||
        suppressed is! int) {
      throw const LarenorServerException('invalid_response');
    }
    return AutomationTrial(
      id: serverText(json['id'], max: 32),
      timezone: serverText(json['timezone'], max: 128),
      localStartDate: serverText(json['localStartDate'], max: 10),
      startsAtMs: starts,
      endsAtMs: ends,
      utcDurationSeconds: duration,
      ruleDeviceId: serverText(rules.first['deviceId'], max: 32),
      eventCount: eventCount,
      triggeredCount: triggered,
      suppressedCount: suppressed,
      events: List.unmodifiable(events),
    );
  }

  final String id, timezone, localStartDate, ruleDeviceId;
  final int startsAtMs, endsAtMs, utcDurationSeconds;
  final int eventCount, triggeredCount, suppressedCount;
  final List<AutomationTrialEvent> events;
}
