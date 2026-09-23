import '../../media_preparations/domain/server_media_preparation_models.dart';

const mediaRecoveryServiceOrder = <String>[
  'larenor_core',
  'qbittorrent',
  'sonarr',
  'radarr',
  'jellyfin',
  'seerr',
  'music_assistant',
];

Never _invalid() => throw const FormatException('invalid_response');

class ServerMediaRecoveryService {
  const ServerMediaRecoveryService._({
    required this.serviceId,
    required this.sourceId,
    required this.sourceKind,
    required this.revision,
    required this.resultState,
    required this.containerState,
    required this.serviceState,
    required this.storedState,
    required this.reachableState,
    required this.verifiedState,
    required this.recoveryAction,
    required this.updatedAt,
  });

  factory ServerMediaRecoveryService.fromJson(Object? value) {
    final map = mediaObject(value, {
      'serviceId',
      'sourceId',
      'sourceKind',
      'revision',
      'resultState',
      'containerState',
      'serviceState',
      'storedState',
      'reachableState',
      'verifiedState',
      'recoveryAction',
      'automaticRetry',
      'errorCode',
      'updatedAt',
    });
    final serviceId = map['serviceId'];
    final sourceKind = map['sourceKind'];
    final sourceId = map['sourceId'];
    final revision = map['revision'];
    final result = map['resultState'];
    final container = map['containerState'];
    final service = map['serviceState'];
    final stored = map['storedState'];
    final reachable = map['reachableState'];
    final verified = map['verifiedState'];
    final action = map['recoveryAction'];
    final error = map['errorCode'];
    final updatedAt = map['updatedAt'];
    final parsedUpdatedAt = updatedAt is String
        ? DateTime.tryParse(updatedAt)
        : null;
    if (serviceId is! String ||
        !mediaRecoveryServiceOrder.contains(serviceId) ||
        sourceKind is! String ||
        !{
          'core',
          'installation',
          'configuration',
          'bootstrap',
          'missing',
        }.contains(sourceKind) ||
        result is! String ||
        !{
          'pending',
          'partial',
          'verified',
          'cancelled',
          'needs_attention',
          'failed',
          'missing',
        }.contains(result) ||
        container is! String ||
        !{'pending', 'started', 'unknown'}.contains(container) ||
        service is! String ||
        !{'unverified', 'verified'}.contains(service) ||
        stored is! String ||
        !{'missing', 'stored'}.contains(stored) ||
        reachable is! String ||
        !{'unknown', 'reachable', 'unreachable'}.contains(reachable) ||
        verified is! String ||
        !{'unverified', 'verified'}.contains(verified) ||
        service != verified ||
        action is! String ||
        !{'wait', 'configure', 'review', 'retry', 'none'}.contains(action) ||
        map['automaticRetry'] != false ||
        (error != null &&
            (error is! String ||
                !RegExp(r'^[a-z][a-z0-9_]{0,127}$').hasMatch(error))) ||
        (updatedAt != null &&
            (updatedAt is! String ||
                updatedAt.length > 40 ||
                !updatedAt.endsWith('Z') ||
                parsedUpdatedAt == null ||
                !parsedUpdatedAt.isUtc))) {
      _invalid();
    }
    if (sourceKind == 'missing') {
      if (sourceId != null ||
          revision != null ||
          stored != 'missing' ||
          result != 'missing' ||
          container != 'unknown' ||
          service != 'unverified' ||
          reachable != 'unknown' ||
          verified != 'unverified' ||
          action != 'configure' ||
          error != null ||
          updatedAt != null) {
        _invalid();
      }
    } else {
      if (sourceId is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(sourceId) ||
          revision is! int ||
          revision < 1 ||
          stored != 'stored' ||
          result == 'missing' ||
          (sourceKind != 'core' && parsedUpdatedAt == null)) {
        _invalid();
      }
    }
    if ((verified == 'verified' && reachable != 'reachable') ||
        (service == 'verified' && container != 'started') ||
        ((serviceId == 'larenor_core') != (sourceKind == 'core')) ||
        (sourceKind == 'core' && result != 'verified') ||
        (result == 'verified' &&
            (container != 'started' ||
                service != 'verified' ||
                action != 'none' ||
                error != null)) ||
        (result == 'pending' && (action != 'wait' || error != null)) ||
        (result == 'partial' &&
            (!{'configure', 'review'}.contains(action) || error != null)) ||
        (result == 'cancelled' && (action != 'none' || error != null)) ||
        (result == 'needs_attention' &&
            (action != 'review' || error == null)) ||
        (result == 'failed' && (action != 'retry' || error == null))) {
      _invalid();
    }
    return ServerMediaRecoveryService._(
      serviceId: serviceId,
      sourceId: sourceId as String?,
      sourceKind: sourceKind,
      revision: revision as int?,
      resultState: result,
      containerState: container,
      serviceState: service,
      storedState: stored,
      reachableState: reachable,
      verifiedState: verified,
      recoveryAction: action,
      updatedAt: parsedUpdatedAt,
    );
  }

  final String serviceId;
  final String? sourceId;
  final String sourceKind, resultState, containerState, serviceState;
  final String storedState, reachableState;
  final String verifiedState, recoveryAction;
  final int? revision;
  final DateTime? updatedAt;
}

class ServerMediaRecoveryStatus {
  const ServerMediaRecoveryStatus._(this.state, this.services);

  factory ServerMediaRecoveryStatus.fromJson(Object? value) {
    final map = mediaObject(value, {
      'schemaVersion',
      'state',
      'installAvailable',
      'services',
    });
    if (map['schemaVersion'] != 2 || map['installAvailable'] != false) {
      _invalid();
    }
    final state = map['state'];
    final raw = map['services'];
    if (state is! String ||
        !{'incomplete', 'attention', 'ready'}.contains(state) ||
        raw is! List ||
        raw.length != mediaRecoveryServiceOrder.length) {
      _invalid();
    }
    final services = raw.map(ServerMediaRecoveryService.fromJson).toList();
    if ([for (final item in services) item.serviceId].join('|') !=
        mediaRecoveryServiceOrder.join('|')) {
      _invalid();
    }
    final expected =
        services.any(
          (item) => {'needs_attention', 'failed'}.contains(item.resultState),
        )
        ? 'attention'
        : services.every((item) => item.resultState == 'verified')
        ? 'ready'
        : 'incomplete';
    if (state != expected) _invalid();
    return ServerMediaRecoveryStatus._(state, List.unmodifiable(services));
  }

  final String state;
  final List<ServerMediaRecoveryService> services;
}
