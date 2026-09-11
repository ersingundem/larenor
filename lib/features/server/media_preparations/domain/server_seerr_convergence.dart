import '../../domain/server_models.dart';
import 'server_media_preparation_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

DateTime _time(Object? value) {
  if (value is! String ||
      value.length != 24 ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')
          .hasMatch(value)) {
    _invalid();
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || parsed.toIso8601String() != value) _invalid();
  return parsed;
}

class ServerSeerrConvergence {
  ServerSeerrConvergence._({
    required this.id,
    required this.requestId,
    required this.installationId,
    required this.sourceBootstrapId,
    required this.sourceBootstrapRevision,
    required this.revision,
    required this.state,
    required this.publicPhase,
    required this.phase,
    required this.errorCode,
    required this.arrWired,
    required this.initialized,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ServerSeerrConvergence.fromJson(Object? value) {
    final map = mediaObject(value, {
      'id',
      'requestId',
      'installationId',
      'sourceBootstrapId',
      'sourceBootstrapRevision',
      'serviceId',
      'revision',
      'state',
      'phase',
      'errorCode',
      'installAvailable',
      'convergencePhase',
      'arrWired',
      'initialized',
      'createdAt',
      'updatedAt',
    });
    const states = {
      'queued',
      'running',
      'succeeded',
      'needs_attention',
      'failed',
      'cancelled',
    };
    const publicPhases = {'queued', 'bootstrapping', 'complete'};
    const phases = {
      'queued',
      'bootstrap',
      'arr_wiring',
      'initialize',
      'verified',
    };
    const errors = {
      'seerr_bootstrap_authority_changed',
      'seerr_bootstrap_resources_unavailable',
      'seerr_bootstrap_endpoint_unavailable',
      'seerr_bootstrap_endpoint_changed',
      'seerr_bootstrap_peer_changed',
      'seerr_bootstrap_initial_admin_failed',
      'seerr_bootstrap_arr_wiring_failed',
      'seerr_bootstrap_initialization_failed',
      'seerr_bootstrap_timeout',
      'seerr_bootstrap_interrupted',
      'seerr_bootstrap_worker_unavailable',
      'invalid_seerr_bootstrap_result',
    };
    if (map['serviceId'] != 'seerr' ||
        map['installAvailable'] != false ||
        !states.contains(map['state']) ||
        !publicPhases.contains(map['phase']) ||
        !phases.contains(map['convergencePhase']) ||
        map['arrWired'] is! bool ||
        map['initialized'] is! bool ||
        map['errorCode'] != null && !errors.contains(map['errorCode'])) {
      _invalid();
    }
    final state = map['state'] as String;
    final publicPhase = map['phase'] as String;
    final phase = map['convergencePhase'] as String;
    final revision = mediaInteger(map['revision'], max: 0x7ffffffffffffffe);
    final arrWired = map['arrWired'] as bool;
    final initialized = map['initialized'] as bool;
    final error = map['errorCode'] as String?;
    final createdAt = _time(map['createdAt']);
    final updatedAt = _time(map['updatedAt']);
    final rank = switch (phase) {
      'queued' => 0,
      'bootstrap' => 1,
      'arr_wiring' => 2,
      'initialize' => 3,
      _ => 4,
    };
    if (updatedAt.isBefore(createdAt) ||
        state == 'queued' &&
            (publicPhase != 'queued' ||
                revision != 1 ||
                error != null ||
                rank != 0) ||
        state == 'running' &&
            (publicPhase != 'bootstrapping' ||
                revision < 2 ||
                error != null ||
                rank != 1) ||
        state != 'queued' &&
            state != 'running' &&
            (publicPhase != 'complete' || revision < 2) ||
        (state == 'succeeded' || state == 'cancelled') && error != null ||
        (state == 'needs_attention' || state == 'failed') && error == null ||
        arrWired != (rank >= 3) ||
        initialized != (rank == 4) ||
        state == 'succeeded' && rank != 4 ||
        error == 'seerr_bootstrap_initial_admin_failed' && rank != 1 ||
        error == 'seerr_bootstrap_arr_wiring_failed' && rank != 2 ||
        error == 'seerr_bootstrap_initialization_failed' && rank != 3) {
      _invalid();
    }
    return ServerSeerrConvergence._(
      id: mediaId(map['id']),
      requestId: mediaId(map['requestId']),
      installationId: mediaId(map['installationId']),
      sourceBootstrapId: mediaId(map['sourceBootstrapId']),
      sourceBootstrapRevision: mediaInteger(
        map['sourceBootstrapRevision'],
        max: 0x7ffffffffffffffe,
      ),
      revision: revision,
      state: state,
      publicPhase: publicPhase,
      phase: phase,
      errorCode: error,
      arrWired: arrWired,
      initialized: initialized,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  final String id, requestId, installationId, sourceBootstrapId;
  final String state, publicPhase, phase;
  final int sourceBootstrapRevision, revision;
  final String? errorCode;
  final bool arrWired, initialized;
  final DateTime createdAt, updatedAt;
  bool get cancelled => state == 'cancelled';
  bool get needsRecovery => state == 'needs_attention' || state == 'failed';
}
