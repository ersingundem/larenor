import '../../admin/data/models/ha_area.dart';
import '../../admin/data/models/ha_device.dart';
import '../../admin/data/models/ha_registry_entry.dart';
import '../../ha_client/data/models/ha_entity.dart';
import 'dashboard_room.dart';
import 'ha_area_binding.dart';
import 'home_domains.dart';

/// Complete successful registry reads. Failed reads never construct this type.
class AreaSyncSnapshot {
  AreaSyncSnapshot({
    required this.serverUrl,
    required Iterable<HaArea> areas,
    required Iterable<HaDevice> devices,
    required Iterable<HaRegistryEntry> registry,
    required Map<String, HaEntity> entities,
  }) : areas = _indexed(areas, (area) => area.areaId, 500),
       devices = _indexed(devices, (device) => device.id, 50000),
       registry = _indexed(registry, (entry) => entry.entityId, 50000),
       entities = Map.unmodifiable(entities) {
    const invalid = FormatException('Invalid area registry snapshot');
    if (normalizedAreaServerUrl(serverUrl) != serverUrl ||
        entities.length > 50000) {
      throw invalid;
    }
    for (final area in this.areas.values) {
      if (area.name.isEmpty ||
          area.name.length > 256 ||
          area.name.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw invalid;
      }
    }
    final entityId = RegExp(r'^[a-z0-9_]+\.[a-z0-9_]+$');
    if (this.registry.keys.any((id) => !entityId.hasMatch(id)) ||
        entities.entries.any(
          (entry) =>
              entry.key != entry.value.entityId ||
              entry.key.length > 256 ||
              !entityId.hasMatch(entry.key),
        )) {
      throw invalid;
    }
  }
  final String serverUrl;
  final Map<String, HaArea> areas;
  final Map<String, HaDevice> devices;
  final Map<String, HaRegistryEntry> registry;
  final Map<String, HaEntity> entities;
}

class RoomAreaSyncChange {
  RoomAreaSyncChange({
    required this.before,
    required this.after,
    Iterable<String> added = const [],
    Iterable<String> removed = const [],
    Iterable<String> heldUnknown = const [],
    this.missingArea = false,
  }) : added = List.unmodifiable(added),
       removed = List.unmodifiable(removed),
       heldUnknown = List.unmodifiable(heldUnknown);
  final DashboardRoom before;
  final DashboardRoom after;
  final List<String> added;
  final List<String> removed;
  final List<String> heldUnknown;
  final bool missingArea;
  bool get renamed => before.name != after.name;
  bool get hasChanges => before != after;
}

/// Local membership provenance: manual members survive; removed imported
/// members remain excluded; existing order is stable and new IDs append.
RoomAreaSyncChange buildRoomAreaSyncChange({
  required DashboardRoom room,
  required AreaSyncSnapshot snapshot,
  required String areaId,
}) {
  final existingBinding = room.areaBinding;
  if (existingBinding != null &&
      (existingBinding.serverUrl != snapshot.serverUrl ||
          existingBinding.areaId != areaId)) {
    throw const FormatException(
      'Room must be detached before changing its binding',
    );
  }
  final area = snapshot.areas[areaId];
  if (area == null) {
    return RoomAreaSyncChange(before: room, after: room, missingArea: true);
  }
  final imported = existingBinding?.importedEntityIds.toSet() ?? <String>{};
  final excluded = existingBinding?.excludedEntityIds.toSet() ?? <String>{};
  final manual = room.entityIds.toSet().difference(imported);
  final desired = <String>{};
  final unknown = <String>{};
  for (final entry in snapshot.registry.values) {
    String? resolved = entry.areaId;
    var unresolved = false;
    if (resolved == null && entry.deviceId != null) {
      final device = snapshot.devices[entry.deviceId];
      if (device == null) {
        unresolved = true;
      } else {
        resolved = device.areaId;
      }
    }
    if (unresolved) {
      if (imported.contains(entry.entityId)) unknown.add(entry.entityId);
      continue;
    }
    if (resolved != areaId) continue;
    if (imported.contains(entry.entityId)) {
      // Missing/unavailable state and disabled/hidden registry flags do not
      // erase already accepted membership. Only a known move/delete does.
      desired.add(entry.entityId);
      continue;
    }
    if (entry.disabledBy != null || entry.hiddenBy != null) continue;
    final entity = snapshot.entities[entry.entityId];
    if (entity != null && _isHomeCandidate(entity)) desired.add(entry.entityId);
  }
  desired.addAll(unknown);
  desired.removeAll(excluded);
  final nextImported = desired.difference(manual);
  final removed = imported.difference(nextImported);
  final additions = nextImported.difference(room.entityIds.toSet()).toList()
    ..sort();
  final nextIds = [
    for (final id in room.entityIds)
      if (!removed.contains(id)) id,
    ...additions,
  ];
  final nextName =
      existingBinding != null && room.name == existingBinding.sourceName
      ? area.name
      : room.name;
  final next = room.copyWith(
    name: nextName,
    entityIds: nextIds,
    areaBinding: HaAreaBinding(
      serverUrl: snapshot.serverUrl,
      areaId: areaId,
      sourceName: area.name,
      importedEntityIds: nextIds.where(nextImported.contains),
      excludedEntityIds: excluded,
    ),
  );
  return RoomAreaSyncChange(
    before: room,
    after: next,
    added: additions,
    removed: room.entityIds.where(removed.contains),
    heldUnknown: unknown.toList()..sort(),
  );
}

Map<String, T> _indexed<T>(
  Iterable<T> source,
  String Function(T) key,
  int limit,
) {
  const invalid = FormatException('Invalid area registry snapshot');
  final indexed = <String, T>{};
  for (final item in source) {
    final id = key(item);
    if (id.isEmpty ||
        id.length > 256 ||
        id.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        indexed.length >= limit ||
        indexed.containsKey(id)) {
      throw invalid;
    }
    indexed[id] = item;
  }
  return Map.unmodifiable(indexed);
}

bool _isHomeCandidate(HaEntity entity) {
  final deviceClass = entity.attributes['device_class'];
  if ((entity.domain == 'sensor' || entity.domain == 'binary_sensor') &&
      deviceClass != null &&
      deviceClass is! String) {
    return false;
  }
  return isHomeEntity(entity);
}
