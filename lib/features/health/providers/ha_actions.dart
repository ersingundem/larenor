import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ha_client/data/ha_api_exception.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/data/rest_client.dart';
import '../../ha_client/data/ws_client.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../ha_client/providers/ha_health_bindings.dart';
import '../data/action_controller.dart';
import '../data/action_receipt.dart';
import '../data/integration_health.dart';
import 'action_providers.dart';

final haActionExecutorProvider = Provider.autoDispose<HaActionExecutor>(
  (ref) => HaActionExecutor(
    controller: ref.watch(actionControllerProvider),
    rest: ref.watch(haRestClientProvider),
    ws: ref.watch(haWebSocketClientProvider),
  ),
);

class HaActionExecutor {
  HaActionExecutor({required this.controller, this.rest, this.ws});
  final ActionController controller;
  final HaRestClient? rest;
  final HaWebSocketClient? ws;

  Future<void> execute({
    required String domain,
    required String service,
    required String entityId,
    Map<String, dynamic>? serviceData,
  }) async {
    final receipt = await executeWithReceipt(
      domain: domain,
      service: service,
      entityId: entityId,
      serviceData: serviceData,
    );
    if (receipt.status == ActionStatus.failed ||
        receipt.status == ActionStatus.unknown) {
      throw ActionExecutionException(receipt);
    }
  }

  Future<ActionReceipt> executeWithReceipt({
    required String domain,
    required String service,
    required String entityId,
    Map<String, dynamic>? serviceData,
    Duration acknowledgementTimeout = const Duration(seconds: 30),
    Duration confirmationTimeout = const Duration(seconds: 10),
  }) {
    final data = Map<String, dynamic>.of(serviceData ?? const {});
    // Payload targets cannot widen the one target protected by this guard.
    if (data.keys.any(
      {'entity_id', 'device_id', 'area_id', 'floor_id', 'label_id'}.contains,
    )) {
      throw ArgumentError('Action targets must use the entityId parameter.');
    }
    final expected = expectedHaState(entityId, service, data);
    return controller.execute<HaEntity>(
      key: ActionKey(
        integration: IntegrationId.ha,
        target: entityId,
        action: '$domain.$service',
      ),
      send: () async {
        final client = rest;
        if (client == null) {
          throw HaApiException(
            'Connection is not ready.',
            code: 'not_connected',
          );
        }
        await client.callService(
          domain,
          service,
          entityId: entityId,
          serviceData: data,
        );
      },
      observations: expected == null
          ? null
          : ws?.entityUpdates.where((entity) => entity.entityId == entityId),
      confirms: expected == null || ws == null
          ? null
          : (entity) => entity.entityId == entityId && expected(entity),
      classifyFailure: classifyHaActionFailure,
      acknowledgementTimeout: acknowledgementTimeout,
      confirmationTimeout: confirmationTimeout,
    );
  }
}

/// Only observable settings/states with an unambiguous service meaning.
/// Matching does not claim that a lock bolt, temperature or cover physically
/// reached its target; it means HA reported the requested state/setpoint.
bool Function(HaEntity)? expectedHaState(
  String entityId,
  String service,
  Map<String, dynamic> data,
) {
  final domain = entityId.split('.').first;
  bool only(Set<String> keys) => data.keys.every(keys.contains);
  if (domain == 'light' && service == 'turn_on' && data.isNotEmpty) {
    if (!only({'brightness', 'brightness_pct'})) return null;
    final direct = data['brightness'];
    final percent = data['brightness_pct'];
    if ((direct != null &&
            (direct is! num ||
                !direct.isFinite ||
                direct < 0 ||
                direct > 255)) ||
        (percent != null &&
            (percent is! num ||
                !percent.isFinite ||
                percent < 0 ||
                percent > 100))) {
      return null;
    }
    final target = direct is num
        ? direct.toDouble()
        : percent is num
        ? percent * 255 / 100
        : null;
    if (target == null ||
        (direct is num &&
            percent is num &&
            (direct - percent * 255 / 100).abs() > 1)) {
      return null;
    }
    return (entity) {
      if (target == 0) return entity.state == 'off';
      final brightness = entity.attributes['brightness'];
      return entity.state == 'on' &&
          brightness is num &&
          brightness.isFinite &&
          (brightness - target).abs() <= 1;
    };
  }
  if ({
    'light',
    'switch',
    'input_boolean',
    'fan',
    'humidifier',
    'siren',
  }.contains(domain)) {
    if (service == 'turn_on' && data.isEmpty) {
      return (entity) => entity.state == 'on';
    }
    if (service == 'turn_off' && data.isEmpty) {
      return (entity) => entity.state == 'off';
    }
  }
  if (domain == 'lock') {
    if (service == 'lock' && only({'code'})) {
      return (entity) => entity.state == 'locked';
    }
    if (service == 'unlock' && only({'code'})) {
      return (entity) => entity.state == 'unlocked';
    }
  }
  if (domain == 'cover') {
    if (service == 'open_cover' && data.isEmpty) {
      return (entity) => entity.state == 'open';
    }
    if (service == 'close_cover' && data.isEmpty) {
      return (entity) => entity.state == 'closed';
    }
    if (service == 'set_cover_position' &&
        only({'position'}) &&
        data['position'] is num) {
      return (entity) =>
          _sameNumber(entity.attributes['current_position'], data['position']);
    }
  }
  if (domain == 'media_player') {
    if (service == 'media_play' && data.isEmpty) {
      return (entity) => entity.state == 'playing';
    }
    if (service == 'media_pause' && data.isEmpty) {
      return (entity) => entity.state == 'paused';
    }
    if (service == 'volume_set' &&
        only({'volume_level'}) &&
        data['volume_level'] is num) {
      return (entity) =>
          _sameNumber(entity.attributes['volume_level'], data['volume_level']);
    }
    if (service == 'volume_mute' &&
        only({'is_volume_muted'}) &&
        data['is_volume_muted'] is bool) {
      return (entity) =>
          entity.attributes['is_volume_muted'] == data['is_volume_muted'];
    }
  }
  if (domain == 'climate') {
    if (service == 'set_hvac_mode' &&
        only({'hvac_mode'}) &&
        data['hvac_mode'] is String) {
      return (entity) => entity.state == data['hvac_mode'];
    }
    if (service == 'set_temperature' &&
        only({
          'temperature',
          'target_temp_high',
          'target_temp_low',
          'hvac_mode',
        })) {
      final values = <String, num>{
        for (final field in [
          'temperature',
          'target_temp_high',
          'target_temp_low',
        ])
          if (data[field] is num) field: data[field] as num,
      };
      if (values.isNotEmpty) {
        return (entity) =>
            (data['hvac_mode'] == null || entity.state == data['hvac_mode']) &&
            values.entries.every(
              (entry) => _sameNumber(entity.attributes[entry.key], entry.value),
            );
      }
    }
  }
  return null;
}

bool _sameNumber(dynamic actual, dynamic expected) =>
    actual is num &&
    expected is num &&
    actual.isFinite &&
    expected.isFinite &&
    (actual - expected).abs() < 0.0001;
