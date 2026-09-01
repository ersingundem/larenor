import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../admin/data/models/ha_area.dart';
import '../../admin/data/models/ha_device.dart';
import '../../admin/data/models/ha_registry_entry.dart';
import '../../admin/providers/admin_providers.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../domain/home_domains.dart';
import 'dashboard_providers.dart';

part 'home_dashboard_providers.g.dart';

/// One room section of the dashboard — a Home Assistant area plus the
/// entities that resolve to it.
class HomeRoom {
  const HomeRoom({required this.area, required this.entities});

  final HaArea area;
  final List<HaEntity> entities;
}

/// Everything the home dashboard renders, already grouped and filtered.
class HomeDashboardData {
  const HomeDashboardData({
    required this.rooms,
    required this.unassigned,
    required this.favorites,
    required this.lightsOn,
  });

  final List<HomeRoom> rooms;

  /// Entities that pass the home filter but belong to no area — either
  /// genuinely unassigned, or (commonly) because the saved token isn't an
  /// admin one, so the area/device registries came back empty.
  final List<HaEntity> unassigned;

  final List<HaEntity> favorites;
  final int lightsOn;

  bool get isEmpty => rooms.isEmpty && unassigned.isEmpty && favorites.isEmpty;
}

/// Resolves the area an entity belongs to, following Home Assistant's own
/// inheritance rule: an entity registry entry may name an area directly,
/// otherwise it inherits the area of the device it belongs to.
String? resolveEntityAreaId(
  String entityId,
  Map<String, HaRegistryEntry> registryByEntityId,
  Map<String, HaDevice> devicesById,
) {
  final entry = registryByEntityId[entityId];
  if (entry == null) return null;
  if (entry.areaId != null) return entry.areaId;
  final deviceId = entry.deviceId;
  if (deviceId == null) return null;
  return devicesById[deviceId]?.areaId;
}

/// Pure grouping logic, kept free of Riverpod so it can be unit tested
/// against plain fixtures.
HomeDashboardData buildHomeDashboard({
  required List<HaEntity> entities,
  required List<HaArea> areas,
  required List<HaRegistryEntry> registry,
  required List<HaDevice> devices,
  required List<String> favoriteEntityIds,
  required List<String> hiddenEntityIds,
}) {
  final registryByEntityId = {for (final e in registry) e.entityId: e};
  final devicesById = {for (final d in devices) d.id: d};
  final hidden = hiddenEntityIds.toSet();

  final visible =
      entities
          .where((e) => isHomeEntity(e) && !hidden.contains(e.entityId))
          .toList()
        ..sort((a, b) => a.friendlyName.compareTo(b.friendlyName));

  final byArea = <String, List<HaEntity>>{};
  final unassigned = <HaEntity>[];
  for (final entity in visible) {
    final areaId = resolveEntityAreaId(
      entity.entityId,
      registryByEntityId,
      devicesById,
    );
    if (areaId == null) {
      unassigned.add(entity);
    } else {
      byArea.putIfAbsent(areaId, () => []).add(entity);
    }
  }

  final sortedAreas = [...areas]..sort((a, b) => a.name.compareTo(b.name));
  final rooms = [
    for (final area in sortedAreas)
      if (byArea[area.areaId]?.isNotEmpty ?? false)
        HomeRoom(area: area, entities: byArea[area.areaId]!),
  ];

  // An area id with no matching area (stale registry entry) shouldn't
  // silently swallow its entities — fold them into the unassigned bucket.
  final knownAreaIds = {for (final area in areas) area.areaId};
  for (final entry in byArea.entries) {
    if (!knownAreaIds.contains(entry.key)) unassigned.addAll(entry.value);
  }
  unassigned.sort((a, b) => a.friendlyName.compareTo(b.friendlyName));

  final visibleById = {for (final e in visible) e.entityId: e};
  final favorites = [
    for (final id in favoriteEntityIds)
      if (visibleById[id] != null) visibleById[id]!,
  ];

  final lightsOn = visible.where((e) => e.domain == 'light' && e.isOn).length;

  return HomeDashboardData(
    rooms: rooms,
    unassigned: unassigned,
    favorites: favorites,
    lightsOn: lightsOn,
  );
}

/// The dashboard, derived from Home Assistant rather than hand-assembled:
/// rooms come from HA's area registry, membership from the entity/device
/// registries, and live state from [entitiesProvider].
@riverpod
Future<HomeDashboardData> homeDashboard(Ref ref) async {
  final entities = await ref.watch(entitiesProvider.future);
  final layout = await ref.watch(dashboardLayoutProvider.future);

  // The registry calls are admin-gated. If the saved token isn't an admin
  // token they throw or come back empty — in that case every entity simply
  // lands in the "Other" section instead of the screen failing outright.
  List<HaArea> areas;
  List<HaRegistryEntry> registry;
  List<HaDevice> devices;
  try {
    areas = await ref.watch(areasProvider.future);
    registry = await ref.watch(entityRegistryProvider.future);
    devices = await ref.watch(devicesProvider.future);
  } catch (_) {
    areas = const [];
    registry = const [];
    devices = const [];
  }

  return buildHomeDashboard(
    entities: entities.values.toList(),
    areas: areas,
    registry: registry,
    devices: devices,
    favoriteEntityIds: layout.favoriteEntityIds,
    hiddenEntityIds: layout.hiddenEntityIds,
  );
}
