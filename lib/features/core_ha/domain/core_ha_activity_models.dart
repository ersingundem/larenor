import '../../home_resources/domain/home_resource_models.dart';
import '../../server/domain/server_models.dart';
import 'core_ha_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

void _schema(Object? value) {
  if (value is! int || value != 1) _invalid();
}

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

void _resourceRef(Object? value, HomeResourceRecord target) {
  final ref = _object(value, {
    'schemaVersion',
    'coreId',
    'homeId',
    'kind',
    'id',
  });
  _schema(ref['schemaVersion']);
  if (target.kind != HomeResourceKind.resource ||
      ref['kind'] != 'resource' ||
      ref['id'] != target.id ||
      ref['coreId'] != target.context.coreId ||
      ref['homeId'] != target.context.homeId) {
    _invalid();
  }
}

enum CoreHaAttributionSource { coreApi, coreRule, unknown }

enum CoreHaAttributionReason { explicitCommand, explicitRuleExecution, unknown }

final class CoreHaAttribution {
  const CoreHaAttribution._({
    required this.correlationId,
    required this.source,
    required this.reason,
    required this.serviceId,
    required this.serviceRevision,
    required this.ruleId,
    required this.ruleRevision,
    required this.executionId,
  });

  final String correlationId;
  final CoreHaAttributionSource source;
  final CoreHaAttributionReason reason;
  final String? serviceId;
  final int? serviceRevision;
  final String? ruleId;
  final int? ruleRevision;
  final String? executionId;

  factory CoreHaAttribution.fromJson(Object? raw) {
    if (raw is! Map) _invalid();
    final ruleOrigin = raw['source'] == 'core_rule';
    final keys = {
      'schemaVersion',
      'correlationId',
      'source',
      'reason',
      'serviceId',
      'serviceRevision',
      if (ruleOrigin) ...{'ruleId', 'ruleRevision', 'executionId'},
    };
    final value = _object(raw, keys);
    _schema(value['schemaVersion']);
    final source = switch (value['source']) {
      'core_api' => CoreHaAttributionSource.coreApi,
      'core_rule' => CoreHaAttributionSource.coreRule,
      'unknown' => CoreHaAttributionSource.unknown,
      _ => _invalid(),
    };
    final reason = switch (value['reason']) {
      'explicit_command_request' => CoreHaAttributionReason.explicitCommand,
      'explicit_rule_execution' =>
        CoreHaAttributionReason.explicitRuleExecution,
      'unknown' => CoreHaAttributionReason.unknown,
      _ => _invalid(),
    };
    final correlationId = _id(value['correlationId']);
    final rawService = value['serviceId'];
    final rawRevision = value['serviceRevision'];
    final rawRule = value['ruleId'];
    final rawRuleRevision = value['ruleRevision'];
    final rawExecution = value['executionId'];
    if ((rawService == null) != (rawRevision == null) ||
        rawRevision != null &&
            (rawRevision is! int ||
                rawRevision < 1 ||
                rawRevision > 9223372036854775807) ||
        rawRuleRevision != null &&
            (rawRuleRevision is! int ||
                rawRuleRevision < 1 ||
                rawRuleRevision > 9223372036854775807)) {
      _invalid();
    }
    final serviceId = rawService == null ? null : _id(rawService);
    final ruleId = rawRule == null ? null : _id(rawRule);
    final executionId = rawExecution == null ? null : _id(rawExecution);
    final valid = switch ((source, reason)) {
      (
        CoreHaAttributionSource.coreApi,
        CoreHaAttributionReason.explicitCommand,
      ) =>
        serviceId != null &&
            ruleId == null &&
            rawRuleRevision == null &&
            executionId == null,
      (
        CoreHaAttributionSource.coreRule,
        CoreHaAttributionReason.explicitRuleExecution,
      ) =>
        serviceId != null &&
            ruleId != null &&
            rawRuleRevision != null &&
            executionId == correlationId,
      (CoreHaAttributionSource.unknown, CoreHaAttributionReason.unknown) =>
        serviceId == null &&
            ruleId == null &&
            rawRuleRevision == null &&
            executionId == null,
      _ => false,
    };
    if (!valid) _invalid();
    return CoreHaAttribution._(
      correlationId: correlationId,
      source: source,
      reason: reason,
      serviceId: serviceId,
      serviceRevision: rawRevision as int?,
      ruleId: ruleId,
      ruleRevision: rawRuleRevision as int?,
      executionId: executionId,
    );
  }
}

final class CoreHaHistoryEntry {
  const CoreHaHistoryEntry._(this.attribution, this.receipt);
  final CoreHaAttribution attribution;
  final CoreHaCommandReceipt receipt;

  factory CoreHaHistoryEntry.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {'attribution', 'receipt'});
    final attribution = CoreHaAttribution.fromJson(value['attribution']);
    final receipt = CoreHaCommandReceipt.fromJson(
      value['receipt'],
      target: target,
    );
    if (attribution.correlationId != receipt.requestId) _invalid();
    return CoreHaHistoryEntry._(attribution, receipt);
  }
}

final class CoreHaHistoryPage {
  const CoreHaHistoryPage._(this.entries, this.nextBefore);
  static const maximumPageSize = 50;
  static const maximumVisibleEntries = 200;
  final List<CoreHaHistoryEntry> entries;
  final String? nextBefore;

  factory CoreHaHistoryPage.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'ref',
      'entries',
      'nextBefore',
    });
    _schema(value['schemaVersion']);
    _resourceRef(value['ref'], target);
    final rawEntries = value['entries'];
    if (rawEntries is! List || rawEntries.length > maximumPageSize) _invalid();
    final entries = List<CoreHaHistoryEntry>.unmodifiable(
      rawEntries.map(
        (entry) => CoreHaHistoryEntry.fromJson(entry, target: target),
      ),
    );
    final ids = <String>{};
    for (var index = 0; index < entries.length; index++) {
      final current = entries[index].receipt;
      if (!ids.add(current.requestId)) _invalid();
      if (index == 0) continue;
      final previous = entries[index - 1].receipt;
      final timeOrder = previous.createdAt.compareTo(current.createdAt);
      if (timeOrder < 0 ||
          timeOrder == 0 &&
              previous.requestId.compareTo(current.requestId) <= 0) {
        _invalid();
      }
    }
    final cursor = value['nextBefore'];
    if (cursor != null &&
        (entries.isEmpty || _id(cursor) != entries.last.receipt.requestId)) {
      _invalid();
    }
    return CoreHaHistoryPage._(entries, cursor as String?);
  }
}

enum CoreHaHistoryEventKind { baseline, commandWrite }

final class CoreHaHistoryEvent {
  const CoreHaHistoryEvent._({
    required this.sequence,
    required this.kind,
    required this.entry,
  });

  final int sequence;
  final CoreHaHistoryEventKind kind;
  final CoreHaHistoryEntry entry;
  CoreHaAttribution get attribution => entry.attribution;
  CoreHaCommandReceipt get receipt => entry.receipt;

  factory CoreHaHistoryEvent.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {'sequence', 'kind', 'attribution', 'receipt'});
    final sequence = value['sequence'];
    if (sequence is! int || sequence < 1 || sequence > 2048) _invalid();
    final kind = switch (value['kind']) {
      'baseline' => CoreHaHistoryEventKind.baseline,
      'command_write' => CoreHaHistoryEventKind.commandWrite,
      _ => _invalid(),
    };
    return CoreHaHistoryEvent._(
      sequence: sequence,
      kind: kind,
      entry: CoreHaHistoryEntry.fromJson({
        'attribution': value['attribution'],
        'receipt': value['receipt'],
      }, target: target),
    );
  }
}

final class CoreHaEventHistoryPage {
  const CoreHaEventHistoryPage._({
    required this.chainId,
    required this.headSequence,
    required this.events,
    required this.nextAfter,
  });

  static const maximumPageSize = 50;
  final String chainId;
  final int headSequence;
  final List<CoreHaHistoryEvent> events;
  final int? nextAfter;
  bool get verified => true;

  factory CoreHaEventHistoryPage.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'ref',
      'chainId',
      'headSequence',
      'events',
      'nextAfter',
      'verified',
    });
    _schema(value['schemaVersion']);
    _resourceRef(value['ref'], target);
    final head = value['headSequence'];
    final rawEvents = value['events'];
    if (head is! int ||
        head < 0 ||
        head > 2048 ||
        rawEvents is! List ||
        rawEvents.length > maximumPageSize ||
        value['verified'] != true) {
      _invalid();
    }
    final events = List<CoreHaHistoryEvent>.unmodifiable(
      rawEvents.map(
        (event) => CoreHaHistoryEvent.fromJson(event, target: target),
      ),
    );
    for (var index = 0; index < events.length; index++) {
      final sequence = events[index].sequence;
      if (sequence > head ||
          index > 0 && sequence != events[index - 1].sequence + 1) {
        _invalid();
      }
    }
    final cursor = value['nextAfter'];
    if (cursor != null &&
        (cursor is! int ||
            cursor < 1 ||
            cursor > 2048 ||
            events.isEmpty ||
            cursor != events.last.sequence)) {
      _invalid();
    }
    if (head == 0 && events.isNotEmpty) _invalid();
    return CoreHaEventHistoryPage._(
      chainId: _id(value['chainId']),
      headSequence: head,
      events: events,
      nextAfter: cursor as int?,
    );
  }
}

final class CoreHaHistoryVerification {
  const CoreHaHistoryVerification._({
    required this.chainId,
    required this.sequence,
    required this.headHash,
    required this.checkpoint,
    required this.comparedCheckpoint,
  });

  final String chainId, headHash, checkpoint;
  final int sequence;
  final bool comparedCheckpoint;
  bool get verified => true;
  bool get causalityVerified => false;

  factory CoreHaHistoryVerification.fromJson(
    Object? raw, {
    required ServerContext expectedContext,
    required bool expectedComparison,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'scope',
      'chainId',
      'sequence',
      'headHash',
      'checkpoint',
      'verified',
      'comparedCheckpoint',
      'causalityVerified',
    });
    _schema(value['schemaVersion']);
    final scope = _object(value['scope'], {
      'schemaVersion',
      'coreId',
      'homeId',
    });
    _schema(scope['schemaVersion']);
    final sequence = value['sequence'];
    final head = value['headHash'];
    final checkpoint = value['checkpoint'];
    if (scope['coreId'] != expectedContext.coreId ||
        scope['homeId'] != expectedContext.homeId ||
        sequence is! int ||
        sequence < 0 ||
        sequence > 2048 ||
        head is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(head) ||
        checkpoint is! String ||
        checkpoint.isEmpty ||
        checkpoint.length > 512 ||
        checkpoint.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e) ||
        value['verified'] != true ||
        value['comparedCheckpoint'] != expectedComparison ||
        value['causalityVerified'] != false) {
      _invalid();
    }
    return CoreHaHistoryVerification._(
      chainId: _id(value['chainId']),
      sequence: sequence,
      headHash: head,
      checkpoint: checkpoint,
      comparedCheckpoint: expectedComparison,
    );
  }
}
