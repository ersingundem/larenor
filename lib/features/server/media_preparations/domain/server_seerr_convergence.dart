import '../../domain/server_models.dart';
import 'server_media_preparation_models.dart';

class ServerSeerrConvergence {
  ServerSeerrConvergence._({
    required this.id,
    required this.installationId,
    required this.revision,
    required this.state,
    required this.phase,
    required this.errorCode,
    required this.arrWired,
    required this.initialized,
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
    const phases = {
      'queued',
      'bootstrap',
      'arr_wiring',
      'initialize',
      'verified',
    };
    if (map['serviceId'] != 'seerr' ||
        map['installAvailable'] != false ||
        !states.contains(map['state']) ||
        !phases.contains(map['convergencePhase']) ||
        map['arrWired'] is! bool ||
        map['initialized'] is! bool ||
        map['errorCode'] != null && map['errorCode'] is! String) {
      throw const LarenorServerException('invalid_response');
    }
    final state = map['state'] as String;
    final phase = map['convergencePhase'] as String;
    final arrWired = map['arrWired'] as bool;
    final initialized = map['initialized'] as bool;
    if (state == 'succeeded' &&
            (phase != 'verified' || !arrWired || !initialized) ||
        initialized && !arrWired) {
      throw const LarenorServerException('invalid_response');
    }
    return ServerSeerrConvergence._(
      id: mediaId(map['id']),
      installationId: mediaId(map['installationId']),
      revision: mediaInteger(map['revision']),
      state: state,
      phase: phase,
      errorCode: map['errorCode'] as String?,
      arrWired: arrWired,
      initialized: initialized,
    );
  }

  final String id, installationId, state, phase;
  final int revision;
  final String? errorCode;
  final bool arrWired, initialized;
  bool get needsRecovery => state == 'needs_attention' || state == 'failed';
}
