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

enum CoreHaAttributionSource { coreApi, unknown }

enum CoreHaAttributionReason { explicitCommand, unknown }

final class CoreHaAttribution {
  const CoreHaAttribution._({
    required this.correlationId,
    required this.source,
    required this.reason,
    required this.serviceId,
    required this.serviceRevision,
  });

  final String correlationId;
  final CoreHaAttributionSource source;
  final CoreHaAttributionReason reason;
  final String? serviceId;
  final int? serviceRevision;

  factory CoreHaAttribution.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'correlationId',
      'source',
      'reason',
      'serviceId',
      'serviceRevision',
    });
    _schema(value['schemaVersion']);
    final source = switch (value['source']) {
      'core_api' => CoreHaAttributionSource.coreApi,
      'unknown' => CoreHaAttributionSource.unknown,
      _ => _invalid(),
    };
    final reason = switch (value['reason']) {
      'explicit_command_request' => CoreHaAttributionReason.explicitCommand,
      'unknown' => CoreHaAttributionReason.unknown,
      _ => _invalid(),
    };
    final rawService = value['serviceId'];
    final rawRevision = value['serviceRevision'];
    if ((rawService == null) != (rawRevision == null) ||
        rawRevision != null &&
            (rawRevision is! int ||
                rawRevision < 1 ||
                rawRevision > 9223372036854775807)) {
      _invalid();
    }
    return CoreHaAttribution._(
      correlationId: _id(value['correlationId']),
      source: source,
      reason: reason,
      serviceId: rawService == null ? null : _id(rawService),
      serviceRevision: rawRevision as int?,
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
