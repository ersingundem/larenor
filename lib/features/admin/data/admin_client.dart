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

  // --- Config entries (integrations) -----------------------------------

  Future<List<ConfigEntry>> listConfigEntries() async {
    final result = await _rest.getJson('/api/config/config_entries/entry');
    return (result as List<dynamic>)
        .map((e) => ConfigEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> deleteConfigEntry(String entryId) =>
      _rest.deleteJson('/api/config/config_entries/entry/$entryId');

  Future<void> reloadConfigEntry(String entryId) =>
      _rest.postJson('/api/config/config_entries/entry/$entryId/reload');

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

  Future<FlowStep> startFlow(String handler) async {
    final result = await _rest.postJson('/api/config/config_entries/flow', {
      'handler': handler,
    });
    return FlowStep.fromJson(result as Map<String, dynamic>);
  }

  Future<FlowStep> submitFlowStep(
    String flowId,
    Map<String, dynamic> data,
  ) async {
    final result = await _rest.postJson(
      '/api/config/config_entries/flow/$flowId',
      data,
    );
    return FlowStep.fromJson(result as Map<String, dynamic>);
  }

  Future<void> cancelFlow(String flowId) async {
    try {
      await _rest.deleteJson('/api/config/config_entries/flow/$flowId');
    } catch (_) {
      // Best-effort — the flow simply expires server-side otherwise.
    }
  }

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
