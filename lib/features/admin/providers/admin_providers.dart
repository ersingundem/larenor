import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../data/admin_client.dart';
import '../data/models/automation_summary.dart';
import '../data/models/config_entry.dart';
import '../data/models/ha_area.dart';
import '../data/models/ha_device.dart';
import '../data/models/ha_registry_entry.dart';

part 'admin_providers.g.dart';

@riverpod
HaAdminClient? haAdminClient(Ref ref) {
  final rest = ref.watch(haRestClientProvider);
  final ws = ref.watch(haWebSocketClientProvider);
  if (rest == null || ws == null) return null;
  return HaAdminClient(rest, ws);
}

@riverpod
class ConfigEntries extends _$ConfigEntries {
  @override
  Future<List<ConfigEntry>> build() async {
    final client = ref.watch(haAdminClientProvider);
    if (client == null) return [];
    return client.listConfigEntries();
  }

  Future<void> delete(String entryId) async {
    final client = ref.read(haAdminClientProvider);
    if (client == null) return;
    await client.deleteConfigEntry(entryId);
    state = AsyncData(await client.listConfigEntries());
  }

  Future<void> reload(String entryId) async {
    final client = ref.read(haAdminClientProvider);
    if (client == null) return;
    await client.reloadConfigEntry(entryId);
    state = AsyncData(await client.listConfigEntries());
  }

  Future<void> refresh() async {
    final client = ref.read(haAdminClientProvider);
    if (client == null) return;
    state = AsyncData(await client.listConfigEntries());
  }
}

@riverpod
Future<List<HaDevice>> devices(Ref ref) async {
  final client = ref.watch(haAdminClientProvider);
  if (client == null) return [];
  return client.listDevices();
}

@riverpod
Future<List<HaArea>> areas(Ref ref) async {
  final client = ref.watch(haAdminClientProvider);
  if (client == null) return [];
  return client.listAreas();
}

@riverpod
class EntityRegistry extends _$EntityRegistry {
  @override
  Future<List<HaRegistryEntry>> build() async {
    final client = ref.watch(haAdminClientProvider);
    if (client == null) return [];
    return client.listEntityRegistry();
  }

  Future<void> setDisabled(String entityId, bool disabled) async {
    final client = ref.read(haAdminClientProvider);
    if (client == null) return;
    await client.setEntityDisabled(entityId, disabled);
    state = AsyncData(await client.listEntityRegistry());
  }
}

/// `automation.*` entities joined with their entity-registry `unique_id`.
@riverpod
Future<List<AutomationSummary>> automations(Ref ref) async {
  final client = ref.watch(haAdminClientProvider);
  final entities = await ref.watch(entitiesProvider.future);
  if (client == null) return [];

  final automationEntities = entities.values
      .where((e) => e.domain == 'automation')
      .toList();
  if (automationEntities.isEmpty) return [];

  final registryEntries = await client.getEntityRegistryEntries(
    automationEntities.map((e) => e.entityId).toList(),
  );

  return buildAutomationSummaries(automationEntities, registryEntries);
}

/// Joins automation entities with their registry `unique_id`, sorted by
/// display name. Pulled out of [automations] so it can be unit tested
/// without standing up the provider/network stack.
List<AutomationSummary> buildAutomationSummaries(
  List<HaEntity> automationEntities,
  Map<String, HaRegistryEntry?> registryEntries,
) {
  return automationEntities
      .map(
        (entity) => AutomationSummary(
          entityId: entity.entityId,
          friendlyName: entity.friendlyName,
          isOn: entity.isOn,
          automationId: registryEntries[entity.entityId]?.uniqueId,
        ),
      )
      .toList()
    ..sort((a, b) => a.friendlyName.compareTo(b.friendlyName));
}
