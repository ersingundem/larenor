import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_providers.dart';
import '../../health/data/action_receipt.dart';
import '../../health/data/health_monitor.dart';
import '../../health/data/integration_health.dart';
import '../../health/providers/health_providers.dart';
import '../data/ha_api_exception.dart';
import '../data/ws_client.dart';

final haHealthSessionProvider = Provider.autoDispose<HealthSession>((ref) {
  final connection = ref.watch(connectionConfigProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  final session = ref
      .watch(healthMonitorProvider)
      .bind(
        IntegrationId.ha,
        configured: config != null,
        configurationIdentity: config,
      );
  ref.onDispose(session.close);
  return session;
});

void observeHaConnection(
  HealthSession health,
  HaConnectionObservation observation,
) {
  switch (observation.event) {
    case HaConnectionEvent.connecting:
      health.connecting();
    case HaConnectionEvent.contact:
      health.contact();
    case HaConnectionEvent.liveReady:
      health.liveConnected();
    case HaConnectionEvent.liveContact:
      health.liveContact();
    case HaConnectionEvent.authenticationRejected:
      health.contact();
      health.failed(HealthFailure.authentication);
    case HaConnectionEvent.permissionDenied:
      health.failed(HealthFailure.permission);
    case HaConnectionEvent.disconnected:
      health.liveDisconnected();
    case HaConnectionEvent.retrying:
      health.retrying(observation.retryAttempt);
  }
}

HealthFailure classifyHaReadFailure(Object error) {
  if (error is TimeoutException) return HealthFailure.timeout;
  if (error is HaApiException) {
    if (error.statusCode == 401 || error.code == 'unauthorized') {
      return HealthFailure.authentication;
    }
    if (error.statusCode == 403 || error.code == 'forbidden') {
      return HealthFailure.permission;
    }
    if (error.code == 'timeout') return HealthFailure.timeout;
    if (error.code == 'connection_error' ||
        error.code == 'closed' ||
        error.code == 'not_connected') {
      return HealthFailure.transport;
    }
    if ((error.statusCode ?? 0) >= 500) return HealthFailure.server;
  }
  return HealthFailure.invalidResponse;
}

ActionFailure classifyHaActionFailure(Object error) {
  if (error is TimeoutException) return ActionFailure.timeout;
  if (error is HaApiException) {
    if (error.statusCode == 401) return ActionFailure.authentication;
    if (error.statusCode == 403 ||
        error.code == 'unauthorized' ||
        error.code == 'forbidden') {
      return ActionFailure.permission;
    }
    if (error.code == 'not_connected') return ActionFailure.notConnected;
    if (error.code == 'timeout') return ActionFailure.timeout;
    if (error.code == 'connection_error' || error.code == 'closed') {
      return ActionFailure.transport;
    }
    if ({400, 404, 405, 422}.contains(error.statusCode) ||
        {'invalid_format', 'service_not_found'}.contains(error.code)) {
      return ActionFailure.rejected;
    }
  }
  // A lost response, invalid response or server error may follow execution.
  return ActionFailure.unknown;
}
