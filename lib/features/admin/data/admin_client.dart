import '../../ha_client/data/rest_client.dart';
import '../../ha_client/data/ws_client.dart';
import 'models/config_entry.dart';
import 'models/flow_step.dart';
import 'models/ha_area.dart';
import 'models/ha_device.dart';
import 'models/ha_registry_entry.dart';

/// Thin wrapper over the internal-but-stable endpoints HA's own frontend
/// uses to manage integrations, devices, areas, entities, and automations.
/// See the "API research" section of the admin panel plan for how each of
/// these was verified against home-assistant/core source.
class HaAdminClient {
  HaAdminClient(this._rest, this._ws);

  final HaRestClient _rest;
  final HaWebSocketClient _ws;

  /// Bind local reference updates to the server that accepted the rename.
  String get baseUrl => _rest.baseUrl;

  // --- Config entries (integrations) -----------------------------------

  Future<List<ConfigEntry>> listConfigEntries() async {
    final result = await _rest.getJson('/api/config/config_entries/entry');
    return (result as List<dynamic>)
        .map((e) => ConfigEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<bool> deleteConfigEntry(String entryId) async =>
      (await _rest.deleteJson(
        '/api/config/config_entries/entry/${Uri.encodeComponent(entryId)}',
      ))?['require_restart'] ==
      true;

  Future<bool> reloadConfigEntry(String entryId) async =>
      (await _rest.postJson(
        '/api/config/config_entries/entry/${Uri.encodeComponent(entryId)}/reload',
      ))?['require_restart'] ==
      true;

  Future<List<String>> listFlowHandlers() async {
    final result = await _rest.getJson(
      '/api/config/config_entries/flow_handlers',
    );
    return (result as List<dynamic>)
        .map(
          (e) =>
              e is Map<String, dynamic> ? e['domain'] as String : e as String,
        )
        .toList()
      ..sort();
  }

  Future<FlowStep> startFlow(
    String handler, {
    String? entryId,
    bool options = false,
  }) async {
    final result = await _rest.requestJson(
      'POST',
      _flowPath(options),
      headers: {'HA-Frontend-Base': _rest.baseUrl},
      body: {'handler': handler, 'entry_id': ?entryId},
    );
    return FlowStep.fromJson(result as Map<String, dynamic>);
  }

  Future<FlowStep> submitFlowStep(
    String flowId,
    Map<String, dynamic> data, {
    bool options = false,
  }) async {
    final result = await _rest.requestJson(
      'POST',
      '${_flowPath(options)}/${Uri.encodeComponent(flowId)}',
      body: data,
      headers: {'HA-Frontend-Base': _rest.baseUrl},
    );
    return FlowStep.fromJson(result as Map<String, dynamic>);
  }

  Future<void> cancelFlow(String flowId, {bool options = false}) async {
    try {
      await _rest.deleteJson(
        '${_flowPath(options)}/${Uri.encodeComponent(flowId)}',
      );
    } catch (_) {
      // Best-effort — the flow simply expires server-side otherwise.
    }
  }

  String _flowPath(bool options) =>
      '/api/config/config_entries/${options ? 'options/' : ''}flow';

  Future<FlowStep> getFlow(String flowId, {bool options = false}) async =>
      FlowStep.fromJson(
        await _rest.requestJson(
          'GET',
          '${_flowPath(options)}/${Uri.encodeComponent(flowId)}',
          headers: {'HA-Frontend-Base': _rest.baseUrl},
        ) as Map<String, dynamic>,
      );

  Future<List<Map<String, dynamic>>> getPendingFlows() async {
    final result = await _ws.sendCommand({
      'type': 'config_entries/flow/progress',
    });
    return (result as List)
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
  }

  Future<Map<String, dynamic>> updateConfigEntry(
    String entryId,
    Map<String, dynamic> changes,
  ) async => Map<String, dynamic>.from(
    await _ws.sendCommand({
      'type': 'config_entries/update',
      'entry_id': entryId,
      ...changes,
    }) as Map,
  );

  Future<Map<String, dynamic>> setConfigEntryDisabled(
    String entryId,
    bool disabled,
  ) async => Map<String, dynamic>.from(
    await _ws.sendCommand({
      'type': 'config_entries/disable',
      'entry_id': entryId,
      'disabled_by': disabled ? 'user' : null,
    }) as Map,
  );

  Future<void> createArea(String name) =>
      _ws.sendCommand({'type': 'config/area_registry/create', 'name': name});

  Future<void> updateArea(String areaId, String name) => _ws.sendCommand({
    'type': 'config/area_registry/update',
    'area_id': areaId,
    'name': name,
  });

  Future<void> deleteArea(String areaId) => _ws.sendCommand({
    'type': 'config/area_registry/delete',
    'area_id': areaId,
  });

  Future<void> updateDevice(String deviceId, Map<String, dynamic> changes) =>
      _ws.sendCommand({
        'type': 'config/device_registry/update',
        'device_id': deviceId,
        ...changes,
      });

  Future<Map<String, dynamic>> updateEntity(
    String entityId,
    Map<String, dynamic> changes,
  ) async => Map<String, dynamic>.from(
    await _ws.sendCommand({
      'type': 'config/entity_registry/update',
      'entity_id': entityId,
      ...changes,
    }) as Map,
  );

  // --- Device / area / entity registries (WebSocket) --------------------

  Future<List<HaDevice>> listDevices() async {
    final result = await _ws.sendCommand({
      'type': 'config/device_registry/list',
    });
    return (result as List<dynamic>)
        .map((e) => HaDevice.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<HaArea>> listAreas() async {
    final result = await _ws.sendCommand({'type': 'config/area_registry/list'});
    return (result as List<dynamic>)
        .map((e) => HaArea.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<HaRegistryEntry>> listEntityRegistry() async {
    final result = await _ws.sendCommand({
      'type': 'config/entity_registry/list',
    });
    return (result as List<dynamic>)
        .map((e) => HaRegistryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Batched lookup, used to resolve `automation.*` entity ids to their
  /// config-editor `unique_id` without an N+1 round trip per automation.
  Future<Map<String, HaRegistryEntry?>> getEntityRegistryEntries(
    List<String> entityIds,
  ) async {
    final result = await _ws.sendCommand({
      'type': 'config/entity_registry/get_entries',
      'entity_ids': entityIds,
    }) as Map<String, dynamic>;

    return result.map(
      (key, value) => MapEntry(
        key,
        value == null
            ? null
            : HaRegistryEntry.fromJson(value as Map<String, dynamic>),
      ),
    );
  }

  Future<void> setEntityDisabled(String entityId, bool disabled) =>
      _ws.sendCommand({
        'type': 'config/entity_registry/update',
        'entity_id': entityId,
        'disabled_by': disabled ? 'user' : null,
      });

  // --- Automations (REST config editor) ----------------------------------

  Future<Map<String, dynamic>> getAutomationConfig(String automationId) async {
    final result = await _rest.getJson(
      '/api/config/automation/config/$automationId',
    );
    return result as Map<String, dynamic>;
  }

  Future<void> saveAutomationConfig(
    String automationId,
    Map<String, dynamic> config,
  ) => _rest.postJson('/api/config/automation/config/$automationId', config);

  Future<void> deleteAutomationConfig(String automationId) =>
      _rest.deleteJson('/api/config/automation/config/$automationId');
}
