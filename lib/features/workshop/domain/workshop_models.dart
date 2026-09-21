import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _closed(Object? value, Set<String> keys) {
  final map = serverObject(value);
  if (map.length != keys.length || map.keys.any((key) => !keys.contains(key))) {
    _invalid();
  }
  return map;
}

String _text(Object? value, int maximum) {
  if (value is! String ||
      value.isEmpty ||
      value.length > maximum ||
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    _invalid();
  }
  return value;
}

String _identity(Object? value) {
  final result = _text(value, 32);
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(result)) _invalid();
  return result;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 0x7fffffffffffffff) _invalid();
  return value;
}

double _number(Object? value, {double minimum = 0, double? maximum}) {
  if (value is! num || !value.isFinite) _invalid();
  final result = value.toDouble();
  if (result < minimum || maximum != null && result > maximum) _invalid();
  return result;
}

DateTime _time(Object? value) => DateTime.fromMillisecondsSinceEpoch(
  (_number(value) * 1000).round(),
  isUtc: true,
);

void _scope(Map<String, dynamic> ref, ServerContext context, String kind) {
  if (ref['schemaVersion'] != 1 ||
      ref['coreId'] != context.coreId ||
      ref['homeId'] != context.homeId ||
      ref['kind'] != kind) {
    _invalid();
  }
}

enum WorkshopAction { pause, cancel }

enum WorkshopJobState { idle, printing, paused, completed, error }

enum WorkshopMaterialKind { pla, petg, abs, tpu, asa, other }

enum WorkshopConnectivity { online, offline }

enum WorkshopThermal { normal, warning, runaway }

enum WorkshopFilament { available, low, runout, unknown }

enum WorkshopDoor { closed, open, unknown }

enum WorkshopEmergency { clear, triggered }

enum WorkshopFreshness { current, stale }

enum WorkshopIntentEffect { notDispatched }

T _enum<T>({required Object? value, required Map<String, T> values}) =>
    values[value] ?? _invalid();

@immutable
final class WorkshopServiceRef {
  const WorkshopServiceRef({required this.id, required this.revision});
  final String id;
  final int revision;
}

@immutable
final class WorkshopJob {
  const WorkshopJob({
    required this.revision,
    required this.id,
    required this.state,
    required this.progressPermille,
    required this.remainingSeconds,
  });
  final int revision;
  final String? id;
  final WorkshopJobState state;
  final int progressPermille;
  final int? remainingSeconds;
}

@immutable
final class WorkshopMaterial {
  const WorkshopMaterial({
    required this.revision,
    required this.kind,
    required this.remainingGrams,
  });
  final int revision;
  final WorkshopMaterialKind kind;
  final double remainingGrams;
}

@immutable
final class WorkshopSafety {
  const WorkshopSafety({
    required this.revision,
    required this.connectivity,
    required this.thermal,
    required this.filament,
    required this.door,
    required this.emergency,
    required this.observedAt,
    required this.freshness,
  });
  final int revision;
  final WorkshopConnectivity connectivity;
  final WorkshopThermal thermal;
  final WorkshopFilament filament;
  final WorkshopDoor door;
  final WorkshopEmergency emergency;
  final DateTime observedAt;
  final WorkshopFreshness freshness;

  bool get safe =>
      freshness == WorkshopFreshness.current &&
      connectivity == WorkshopConnectivity.online &&
      thermal == WorkshopThermal.normal &&
      (filament == WorkshopFilament.available ||
          filament == WorkshopFilament.low) &&
      door == WorkshopDoor.closed &&
      emergency == WorkshopEmergency.clear;
}

@immutable
final class WorkshopPrinter {
  const WorkshopPrinter({
    required this.coreId,
    required this.homeId,
    required this.id,
    required this.revision,
    required this.name,
    required this.service,
    required this.job,
    required this.material,
    required this.safety,
    required this.availableActions,
  });

  factory WorkshopPrinter.fromJson(Object? json, ServerContext context) {
    final value = _closed(json, {
      'schemaVersion',
      'ref',
      'revision',
      'name',
      'serviceRef',
      'job',
      'material',
      'safety',
      'availableActions',
    });
    final ref = _closed(value['ref'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
    });
    _scope(ref, context, 'workshop_printer');
    if (value['schemaVersion'] != 1) _invalid();
    final service = _closed(value['serviceRef'], {'id', 'revision'});
    final job = _closed(value['job'], {
      'revision',
      'jobId',
      'state',
      'progressPermille',
      'remainingSeconds',
    });
    final material = _closed(value['material'], {
      'revision',
      'kind',
      'remainingGrams',
    });
    final safety = _closed(value['safety'], {
      'revision',
      'connectivity',
      'thermal',
      'filament',
      'door',
      'emergency',
      'observedAt',
      'freshness',
    });
    final jobState = _enum(
      value: job['state'],
      values: const {
        'idle': WorkshopJobState.idle,
        'printing': WorkshopJobState.printing,
        'paused': WorkshopJobState.paused,
        'completed': WorkshopJobState.completed,
        'error': WorkshopJobState.error,
      },
    );
    final jobId = job['jobId'] == null ? null : _identity(job['jobId']);
    if ((jobState == WorkshopJobState.idle) != (jobId == null)) _invalid();
    final remaining = job['remainingSeconds'];
    if (remaining != null &&
        (remaining is! int || remaining < 0 || remaining > 31536000)) {
      _invalid();
    }
    final progress = job['progressPermille'];
    if (progress is! int || progress < 0 || progress > 1000) _invalid();
    final parsedSafety = WorkshopSafety(
      revision: _revision(safety['revision']),
      connectivity: _enum(
        value: safety['connectivity'],
        values: const {
          'online': WorkshopConnectivity.online,
          'offline': WorkshopConnectivity.offline,
        },
      ),
      thermal: _enum(
        value: safety['thermal'],
        values: const {
          'normal': WorkshopThermal.normal,
          'warning': WorkshopThermal.warning,
          'runaway': WorkshopThermal.runaway,
        },
      ),
      filament: _enum(
        value: safety['filament'],
        values: const {
          'available': WorkshopFilament.available,
          'low': WorkshopFilament.low,
          'runout': WorkshopFilament.runout,
          'unknown': WorkshopFilament.unknown,
        },
      ),
      door: _enum(
        value: safety['door'],
        values: const {
          'closed': WorkshopDoor.closed,
          'open': WorkshopDoor.open,
          'unknown': WorkshopDoor.unknown,
        },
      ),
      emergency: _enum(
        value: safety['emergency'],
        values: const {
          'clear': WorkshopEmergency.clear,
          'triggered': WorkshopEmergency.triggered,
        },
      ),
      observedAt: _time(safety['observedAt']),
      freshness: _enum(
        value: safety['freshness'],
        values: const {
          'current': WorkshopFreshness.current,
          'stale': WorkshopFreshness.stale,
        },
      ),
    );
    final rawActions = value['availableActions'];
    if (rawActions is! List || rawActions.length > 2) _invalid();
    final actions = rawActions
        .map(
          (item) => _enum(
            value: item,
            values: const {
              'pause': WorkshopAction.pause,
              'cancel': WorkshopAction.cancel,
            },
          ),
        )
        .toList(growable: false);
    final expected = !parsedSafety.safe
        ? const <WorkshopAction>[]
        : switch (jobState) {
            WorkshopJobState.printing => const [
              WorkshopAction.pause,
              WorkshopAction.cancel,
            ],
            WorkshopJobState.paused => const [WorkshopAction.cancel],
            _ => const <WorkshopAction>[],
          };
    if (!listEquals(actions, expected)) _invalid();
    return WorkshopPrinter(
      coreId: context.coreId,
      homeId: context.homeId,
      id: _identity(ref['id']),
      revision: _revision(value['revision']),
      name: _text(value['name'], 80),
      service: WorkshopServiceRef(
        id: _identity(service['id']),
        revision: _revision(service['revision']),
      ),
      job: WorkshopJob(
        revision: _revision(job['revision']),
        id: jobId,
        state: jobState,
        progressPermille: progress,
        remainingSeconds: remaining as int?,
      ),
      material: WorkshopMaterial(
        revision: _revision(material['revision']),
        kind: _enum(
          value: material['kind'],
          values: const {
            'pla': WorkshopMaterialKind.pla,
            'petg': WorkshopMaterialKind.petg,
            'abs': WorkshopMaterialKind.abs,
            'tpu': WorkshopMaterialKind.tpu,
            'asa': WorkshopMaterialKind.asa,
            'other': WorkshopMaterialKind.other,
          },
        ),
        remainingGrams: _number(material['remainingGrams'], maximum: 100000),
      ),
      safety: parsedSafety,
      availableActions: List.unmodifiable(actions),
    );
  }

  final String coreId, homeId, id, name;
  final int revision;
  final WorkshopServiceRef service;
  final WorkshopJob job;
  final WorkshopMaterial material;
  final WorkshopSafety safety;
  final List<WorkshopAction> availableActions;

  bool sameAuthority(WorkshopPrinter other) =>
      coreId == other.coreId &&
      homeId == other.homeId &&
      id == other.id &&
      revision == other.revision &&
      service.id == other.service.id &&
      service.revision == other.service.revision &&
      job.revision == other.job.revision &&
      material.revision == other.material.revision &&
      safety.revision == other.safety.revision;
}

@immutable
final class WorkshopPreview {
  const WorkshopPreview({
    required this.coreId,
    required this.homeId,
    required this.id,
    required this.printerId,
    required this.action,
    required this.confirmationToken,
    required this.expiresAt,
  });

  factory WorkshopPreview.fromJson(
    Object? json,
    ServerContext context, {
    required String printerId,
    required WorkshopAction action,
  }) {
    final wrapper = _closed(json, {'preview'});
    final value = _closed(wrapper['preview'], {
      'schemaVersion',
      'id',
      'printerRef',
      'action',
      'confirmationToken',
      'expiresAt',
    });
    final ref = _closed(value['printerRef'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
    });
    _scope(ref, context, 'workshop_printer');
    final token = _text(value['confirmationToken'], 43);
    if (value['schemaVersion'] != 1 ||
        ref['id'] != printerId ||
        value['action'] != action.name ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      _invalid();
    }
    return WorkshopPreview(
      coreId: context.coreId,
      homeId: context.homeId,
      id: _identity(value['id']),
      printerId: printerId,
      action: action,
      confirmationToken: token,
      expiresAt: _time(value['expiresAt']),
    );
  }

  final String coreId, homeId, id, printerId, confirmationToken;
  final WorkshopAction action;
  final DateTime expiresAt;
}

@immutable
final class WorkshopIntentAuthority {
  const WorkshopIntentAuthority({
    required this.printerRevision,
    required this.serviceRevision,
    required this.jobRevision,
    required this.materialRevision,
    required this.safetyRevision,
  });
  final int printerRevision, serviceRevision, jobRevision;
  final int materialRevision, safetyRevision;

  bool matches(WorkshopPrinter printer) =>
      printerRevision == printer.revision &&
      serviceRevision == printer.service.revision &&
      jobRevision == printer.job.revision &&
      materialRevision == printer.material.revision &&
      safetyRevision == printer.safety.revision;
}

@immutable
final class WorkshopIntentReceipt {
  const WorkshopIntentReceipt({
    required this.id,
    required this.sequence,
    required this.printerId,
    required this.action,
    required this.effect,
    required this.authority,
    required this.createdAt,
  });

  factory WorkshopIntentReceipt.fromJson(
    Object? json,
    ServerContext context, {
    required String printerId,
    required WorkshopAction action,
  }) {
    final wrapper = _closed(json, {'receipt'});
    final value = _closed(wrapper['receipt'], {
      'schemaVersion',
      'id',
      'sequence',
      'printerRef',
      'action',
      'state',
      'effect',
      'authority',
      'createdAt',
    });
    final ref = _closed(value['printerRef'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
    });
    final authority = _closed(value['authority'], {
      'printerRevision',
      'serviceRevision',
      'jobRevision',
      'materialRevision',
      'safetyRevision',
    });
    _scope(ref, context, 'workshop_printer');
    if (value['schemaVersion'] != 1 ||
        ref['id'] != printerId ||
        value['action'] != action.name ||
        value['state'] != 'recorded' ||
        value['effect'] != 'notDispatched') {
      _invalid();
    }
    return WorkshopIntentReceipt(
      id: _identity(value['id']),
      sequence: _revision(value['sequence']),
      printerId: printerId,
      action: action,
      effect: WorkshopIntentEffect.notDispatched,
      authority: WorkshopIntentAuthority(
        printerRevision: _revision(authority['printerRevision']),
        serviceRevision: _revision(authority['serviceRevision']),
        jobRevision: _revision(authority['jobRevision']),
        materialRevision: _revision(authority['materialRevision']),
        safetyRevision: _revision(authority['safetyRevision']),
      ),
      createdAt: _time(value['createdAt']),
    );
  }

  final String id, printerId;
  final int sequence;
  final WorkshopAction action;
  final WorkshopIntentEffect effect;
  final WorkshopIntentAuthority authority;
  final DateTime createdAt;
}

/// The deliberately small Client boundary for the F59 workshop surface.
///
/// Implementations own cancellation; callers must never retry a write after an
/// uncertain acknowledgement.
abstract interface class WorkshopGateway {
  Future<List<WorkshopPrinter>> load();

  Future<WorkshopPreview> preview({
    required WorkshopPrinter printer,
    required WorkshopAction action,
    required String requestKey,
  });

  Future<WorkshopIntentReceipt> confirm(WorkshopPreview preview);

  void retire();
}
