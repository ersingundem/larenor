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
    required this.evidence,
  });

  factory AutomationTrialEvent.fromJson(Object? value) {
    final raw = serverObject(value);
    final keys = <String>{
      'schemaVersion',
      'source',
      'eventKey',
      'occurredAtMs',
      'localDateTime',
      'utcOffsetSeconds',
      'fold',
      'decisions',
      'adapterWriteCount',
      if (raw.containsKey('evidence')) 'evidence',
    };
    final json = _closed(raw, keys);
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
      evidence: json.containsKey('evidence')
          ? AutomationTrialEvidence.fromJson(json['evidence'])
          : null,
    );
  }

  final String source, eventKey, localDateTime;
  final int occurredAtMs, utcOffsetSeconds, fold;
  final List<AutomationTrialDecision> decisions;
  final AutomationTrialEvidence? evidence;
}

final class AutomationTrialEvidence {
  const AutomationTrialEvidence({required this.provider, required this.runId});

  factory AutomationTrialEvidence.fromJson(Object? value) {
    final json = _closed(value, const {
      'provider',
      'resourceId',
      'resourceRevision',
      'bindingId',
      'bindingRevision',
      'serviceId',
      'serviceRevision',
      'entityId',
      'registryUniqueId',
      'runId',
      'contextId',
      'traceDigest',
    });
    final provider = json['provider'];
    final runId = json['runId'];
    final digest = json['traceDigest'];
    if (provider != 'home_assistant_trace' ||
        runId is! String ||
        runId.isEmpty ||
        runId.length > 128 ||
        digest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const LarenorServerException('invalid_response');
    }
    for (final key in const [
      'resourceId',
      'bindingId',
      'serviceId',
      'contextId',
    ]) {
      serverText(json[key], max: key == 'contextId' ? 128 : 32);
    }
    for (final key in const [
      'resourceRevision',
      'bindingRevision',
      'serviceRevision',
    ]) {
      final revision = json[key];
      if (revision is! int || revision < 1) {
        throw const LarenorServerException('invalid_response');
      }
    }
    serverText(json['entityId'], max: 128);
    serverText(json['registryUniqueId'], max: 128);
    return AutomationTrialEvidence(provider: provider, runId: runId);
  }

  final String provider, runId;
}

final class AutomationTrialRule {
  const AutomationTrialRule({
    required this.ruleId,
    required this.eventKey,
    required this.deviceId,
    required this.action,
    required this.priority,
    required this.weekdays,
    required this.startMinute,
    required this.endMinute,
  });

  factory AutomationTrialRule.fromJson(Object? value) {
    final json = _closed(value, const {
      'ruleId',
      'eventKey',
      'deviceId',
      'action',
      'priority',
      'weekdays',
      'startMinute',
      'endMinute',
    });
    final priority = json['priority'];
    final weekdays = json['weekdays'];
    final start = json['startMinute'];
    final end = json['endMinute'];
    if (priority is! int ||
        weekdays is! List ||
        weekdays.any((day) => day is! int || day < 0 || day > 6) ||
        start is! int ||
        end is! int ||
        end <= start) {
      throw const LarenorServerException('invalid_response');
    }
    return AutomationTrialRule(
      ruleId: serverText(json['ruleId'], max: 32),
      eventKey: serverText(json['eventKey'], max: 64),
      deviceId: serverText(json['deviceId'], max: 32),
      action: serverText(json['action'], max: 32),
      priority: priority,
      weekdays: List.unmodifiable(weekdays.cast<int>()),
      startMinute: start,
      endMinute: end,
    );
  }

  final String ruleId, eventKey, deviceId, action;
  final int priority, startMinute, endMinute;
  final List<int> weekdays;

  Map<String, dynamic> toJson({bool flipAction = false}) => {
    'ruleId': ruleId,
    'eventKey': eventKey,
    'deviceId': deviceId,
    'action': flipAction
        ? (action == 'turn_on' ? 'turn_off' : 'turn_on')
        : action,
    'priority': priority,
    'weekdays': weekdays,
    'startMinute': startMinute,
    'endMinute': endMinute,
  };
}

final class AutomationTrialReplay {
  const AutomationTrialReplay({
    required this.status,
    required this.unknownReason,
    required this.requiredEventCount,
    required this.availableEventCount,
    required this.changedDecisionCount,
    required this.deterministicFingerprint,
  });

  factory AutomationTrialReplay.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'trialId',
      'status',
      'unknownReason',
      'requiredEventCount',
      'availableEventCount',
      'changedDecisionCount',
      'decisionDiffs',
      'deterministicFingerprint',
      'adapterWriteCount',
      'queueWriteCount',
    });
    final required = json['requiredEventCount'];
    final available = json['availableEventCount'];
    final changed = json['changedDecisionCount'];
    final status = json['status'];
    final reason = json['unknownReason'];
    final fingerprint = json['deterministicFingerprint'];
    if (json['schemaVersion'] != 1 ||
        !{'unknown', 'complete'}.contains(status) ||
        (status == 'unknown') != (reason != null) ||
        required is! int ||
        required < 1 ||
        available is! int ||
        available < 0 ||
        changed is! int ||
        changed < 0 ||
        _objects(json['decisionDiffs']).length != changed ||
        fingerprint is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        json['adapterWriteCount'] != 0 ||
        json['queueWriteCount'] != 0) {
      throw const LarenorServerException('invalid_response');
    }
    return AutomationTrialReplay(
      status: status as String,
      unknownReason: reason as String?,
      requiredEventCount: required,
      availableEventCount: available,
      changedDecisionCount: changed,
      deterministicFingerprint: fingerprint,
    );
  }

  final String status, deterministicFingerprint;
  final String? unknownReason;
  final int requiredEventCount, availableEventCount, changedDecisionCount;
}

final class AutomationTrial {
  const AutomationTrial({
    required this.id,
    required this.timezone,
    required this.localStartDate,
    required this.startsAtMs,
    required this.endsAtMs,
    required this.utcDurationSeconds,
    required this.rules,
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
    final rules = _objects(
      json['rules'],
      max: 32,
    ).map(AutomationTrialRule.fromJson).toList();
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
      rules: List.unmodifiable(rules),
      eventCount: eventCount,
      triggeredCount: triggered,
      suppressedCount: suppressed,
      events: List.unmodifiable(events),
    );
  }

  final String id, timezone, localStartDate;
  final int startsAtMs, endsAtMs, utcDurationSeconds;
  final int eventCount, triggeredCount, suppressedCount;
  final List<AutomationTrialEvent> events;
  final List<AutomationTrialRule> rules;
  String get ruleDeviceId => rules.first.deviceId;
}
