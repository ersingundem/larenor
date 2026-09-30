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

enum WorkshopMaterialKind { pla, petg, abs, tpu, asa, other, unknown }

enum WorkshopConnectivity { online, offline }

enum WorkshopThermal { normal, warning, runaway, unknown }

enum WorkshopFilament { available, low, runout, unknown }

enum WorkshopDoor { closed, open, unknown }

enum WorkshopEmergency { clear, triggered, unknown }

enum WorkshopFreshness { current, stale }

enum WorkshopIntentEffect { notDispatched, applied, unknown }

enum WorkshopExecutionCode { applied, readbackMismatch, workerAckUnknown }

T _enum<T>({required Object? value, required Map<String, T> values}) =>
    values[value] ?? _invalid();

@immutable
final class WorkshopServiceRef {
  const WorkshopServiceRef({required this.id, required this.revision});
  final String id;
  final int revision;
}

@immutable
final class WorkshopServiceCandidate {
  const WorkshopServiceCandidate({
    required this.id,
    required this.revision,
    required this.name,
    required this.kind,
  });

  factory WorkshopServiceCandidate.fromJson(Object? json) {
    final value = _closed(json, {'id', 'revision', 'name', 'kind'});
    final kind = value['kind'];
    if (kind != 'octoprint' && kind != 'moonraker') _invalid();
    return WorkshopServiceCandidate(
      id: _identity(value['id']),
      revision: _revision(value['revision']),
      name: _text(value['name'], 80),
      kind: kind as String,
    );
  }

  final String id, name, kind;
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
  final double? remainingGrams;
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

  bool get stoppingEligible =>
      freshness == WorkshopFreshness.current &&
      connectivity == WorkshopConnectivity.online;
}

@immutable
final class WorkshopHeaterTemperature {
  const WorkshopHeaterTemperature({
    required this.name,
    required this.actualC,
    required this.targetC,
  });
  final String name;
  final double actualC;
  final double? targetC;
}

@immutable
final class WorkshopTemperature {
  const WorkshopTemperature({required this.revision, required this.heaters});
  final int revision;
  final List<WorkshopHeaterTemperature> heaters;
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
    required this.temperature,
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
      'temperature',
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
    final temperature = _closed(value['temperature'], {'revision', 'heaters'});
    final rawHeaters = temperature['heaters'];
    if (rawHeaters is! List || rawHeaters.length > 16) _invalid();
    final heaters = rawHeaters
        .map((raw) {
          final heater = _closed(raw, {'name', 'actualC', 'targetC'});
          final target = heater['targetC'];
          return WorkshopHeaterTemperature(
            name: _text(heater['name'], 128),
            actualC: _number(
              heater['actualC'],
              minimum: -273.15,
              maximum: 1000,
            ),
            targetC: target == null
                ? null
                : _number(target, minimum: -273.15, maximum: 1000),
          );
        })
        .toList(growable: false);
    final heaterNames = heaters.map((heater) => heater.name).toList();
    if (!listEquals(heaterNames, [...heaterNames]..sort()) ||
        heaterNames.toSet().length != heaterNames.length) {
      _invalid();
    }
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
          'unknown': WorkshopThermal.unknown,
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
          'unknown': WorkshopEmergency.unknown,
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
    final allowed = !parsedSafety.stoppingEligible || jobId == null
        ? const <WorkshopAction>[]
        : switch (jobState) {
            WorkshopJobState.printing => const [
              WorkshopAction.pause,
              WorkshopAction.cancel,
            ],
            WorkshopJobState.paused => const [WorkshopAction.cancel],
            _ => const <WorkshopAction>[],
          };
    final expected = allowed.where(actions.contains).toList(growable: false);
    if (!listEquals(actions, expected) ||
        actions.toSet().length != actions.length) {
      _invalid();
    }
    final materialKind = _enum(
      value: material['kind'],
      values: const {
        'pla': WorkshopMaterialKind.pla,
        'petg': WorkshopMaterialKind.petg,
        'abs': WorkshopMaterialKind.abs,
        'tpu': WorkshopMaterialKind.tpu,
        'asa': WorkshopMaterialKind.asa,
        'other': WorkshopMaterialKind.other,
        'unknown': WorkshopMaterialKind.unknown,
      },
    );
    final remainingGrams = material['remainingGrams'] == null
        ? null
        : _number(material['remainingGrams'], maximum: 100000);
    if ((materialKind == WorkshopMaterialKind.unknown) !=
        (remainingGrams == null)) {
      _invalid();
    }
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
        kind: materialKind,
        remainingGrams: remainingGrams,
      ),
      safety: parsedSafety,
      temperature: WorkshopTemperature(
        revision: _revision(temperature['revision']),
        heaters: List.unmodifiable(heaters),
      ),
      availableActions: List.unmodifiable(actions),
    );
  }

  final String coreId, homeId, id, name;
  final int revision;
  final WorkshopServiceRef service;
  final WorkshopJob job;
  final WorkshopMaterial material;
  final WorkshopSafety safety;
  final WorkshopTemperature temperature;
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
    this.execution,
  });

  factory WorkshopIntentReceipt.fromJson(
    Object? json,
    ServerContext context, {
    required String printerId,
    required WorkshopAction action,
  }) {
    final wrapper = _closed(json, {'receipt'});
    final rawValue = serverObject(wrapper['receipt']);
    final version = rawValue['schemaVersion'];
    if (version != 1 && version != 2) _invalid();
    final value = _closed(rawValue, {
      'schemaVersion',
      'id',
      'sequence',
      'printerRef',
      'action',
      'state',
      'effect',
      'authority',
      'createdAt',
      if (version == 2) 'execution',
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
    final effect = _enum(
      value: value['effect'],
      values: const {
        'notDispatched': WorkshopIntentEffect.notDispatched,
        'applied': WorkshopIntentEffect.applied,
        'unknown': WorkshopIntentEffect.unknown,
      },
    );
    WorkshopExecution? execution;
    if (version == 2) {
      final raw = _closed(value['execution'], {
        'commandId',
        'status',
        'code',
        'providerRevision',
        'readback',
      });
      final status = _enum(
        value: raw['status'],
        values: const {
          'applied': WorkshopIntentEffect.applied,
          'unknown': WorkshopIntentEffect.unknown,
        },
      );
      final code = _enum(
        value: raw['code'],
        values: const {
          'applied': WorkshopExecutionCode.applied,
          'readback_mismatch': WorkshopExecutionCode.readbackMismatch,
          'worker_ack_unknown': WorkshopExecutionCode.workerAckUnknown,
        },
      );
      final readback = raw['readback'] == null
          ? null
          : WorkshopCommandReadback.fromJson(
              raw['readback'],
              printerId,
              action,
            );
      if (status != effect ||
          (status == WorkshopIntentEffect.applied) !=
              (code == WorkshopExecutionCode.applied) ||
          (code == WorkshopExecutionCode.workerAckUnknown &&
              readback != null)) {
        _invalid();
      }
      execution = WorkshopExecution(
        commandId: _identity(raw['commandId']),
        status: status,
        code: code,
        providerRevision: _revision(raw['providerRevision']),
        readback: readback,
      );
      if (readback != null &&
          (readback.commandId != execution.commandId ||
              readback.providerRevision != execution.providerRevision)) {
        _invalid();
      }
      if (effect == WorkshopIntentEffect.applied &&
          (readback == null ||
              readback.connectivity != WorkshopConnectivity.online ||
              (action == WorkshopAction.pause
                  ? readback.jobState != WorkshopJobState.paused
                  : readback.jobState != WorkshopJobState.idle &&
                        readback.jobState != WorkshopJobState.completed))) {
        _invalid();
      }
    }
    if (ref['id'] != printerId ||
        value['action'] != action.name ||
        value['state'] != 'recorded' ||
        (version == 1 && effect != WorkshopIntentEffect.notDispatched) ||
        (version == 2 && execution == null)) {
      _invalid();
    }
    return WorkshopIntentReceipt(
      id: _identity(value['id']),
      sequence: _revision(value['sequence']),
      printerId: printerId,
      action: action,
      effect: effect,
      authority: WorkshopIntentAuthority(
        printerRevision: _revision(authority['printerRevision']),
        serviceRevision: _revision(authority['serviceRevision']),
        jobRevision: _revision(authority['jobRevision']),
        materialRevision: _revision(authority['materialRevision']),
        safetyRevision: _revision(authority['safetyRevision']),
      ),
      createdAt: _time(value['createdAt']),
      execution: execution,
    );
  }

  final String id, printerId;
  final int sequence;
  final WorkshopAction action;
  final WorkshopIntentEffect effect;
  final WorkshopIntentAuthority authority;
  final DateTime createdAt;
  final WorkshopExecution? execution;
}

@immutable
final class WorkshopCommandReadback {
  const WorkshopCommandReadback({
    required this.commandId,
    required this.printerId,
    required this.action,
    required this.providerRevision,
    required this.jobRevision,
    required this.jobState,
    required this.connectivity,
    required this.observedAt,
  });

  factory WorkshopCommandReadback.fromJson(
    Object? json,
    String printerId,
    WorkshopAction action,
  ) {
    final value = _closed(json, {
      'schemaVersion',
      'commandId',
      'printerId',
      'action',
      'providerRevision',
      'jobRevision',
      'jobState',
      'connectivity',
      'observedAt',
    });
    if (value['schemaVersion'] != 1 ||
        value['printerId'] != printerId ||
        value['action'] != action.name) {
      _invalid();
    }
    return WorkshopCommandReadback(
      commandId: _identity(value['commandId']),
      printerId: _identity(value['printerId']),
      action: action,
      providerRevision: _revision(value['providerRevision']),
      jobRevision: _revision(value['jobRevision']),
      jobState: _enum(
        value: value['jobState'],
        values: const {
          'idle': WorkshopJobState.idle,
          'printing': WorkshopJobState.printing,
          'paused': WorkshopJobState.paused,
          'completed': WorkshopJobState.completed,
          'error': WorkshopJobState.error,
        },
      ),
      connectivity: _enum(
        value: value['connectivity'],
        values: const {
          'online': WorkshopConnectivity.online,
          'offline': WorkshopConnectivity.offline,
        },
      ),
      observedAt: _time(value['observedAt']),
    );
  }

  final String commandId, printerId;
  final WorkshopAction action;
  final int providerRevision, jobRevision;
  final WorkshopJobState jobState;
  final WorkshopConnectivity connectivity;
  final DateTime observedAt;
}

@immutable
final class WorkshopExecution {
  const WorkshopExecution({
    required this.commandId,
    required this.status,
    required this.code,
    required this.providerRevision,
    required this.readback,
  });
  final String commandId;
  final WorkshopIntentEffect status;
  final WorkshopExecutionCode code;
  final int providerRevision;
  final WorkshopCommandReadback? readback;
}

/// The deliberately small Client boundary for the F59 workshop surface.
///
/// Implementations own cancellation; callers must never retry a write after an
/// uncertain acknowledgement.
abstract interface class WorkshopGateway {
  Future<List<WorkshopServiceCandidate>> catalog();

  Future<List<WorkshopPrinter>> load();

  Future<WorkshopPrinter> register({
    required WorkshopServiceCandidate service,
    required String name,
    required String registrationId,
  });

  Future<WorkshopPreview> preview({
    required WorkshopPrinter printer,
    required WorkshopAction action,
    required String requestKey,
  });

  Future<WorkshopIntentReceipt> confirm(WorkshopPreview preview);

  void retire();
}
