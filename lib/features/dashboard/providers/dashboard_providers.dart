import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/configuration_writes.dart';
import '../data/dashboard_repository.dart';
import '../data/room_area_sync_reader.dart';
import '../domain/dashboard_layout.dart';
import '../domain/dashboard_card_size.dart';
import '../../settings/data/app_service.dart';
import '../domain/dashboard_room.dart';
import '../domain/ha_area_binding.dart';
import '../domain/tile_config.dart';

part 'dashboard_providers.g.dart';

@riverpod
DashboardRepository dashboardRepository(Ref ref) => DashboardRepository();

@riverpod
class DashboardLayoutNotifier extends _$DashboardLayoutNotifier {
  @override
  Future<DashboardLayout> build() =>
      ref.watch(dashboardRepositoryProvider).load();

  Future<void> _mutate(
    DashboardLayout Function(DashboardLayout) transform, {
    bool Function()? isCurrent,
  }) => ConfigurationWrites.run(() async {
    bool current() => ref.mounted && isCurrent?.call() != false;
    if (!current()) throw const RoomAreaSyncException('account_changed');
    final repository = ref.read(dashboardRepositoryProvider);
    // Derive inside the reentrant global queue from durable current state.
    // A restore or concurrent edit cannot be overwritten by an old snapshot.
    final before = await repository.load();
    if (!current()) throw const RoomAreaSyncException('account_changed');
    final next = transform(before).copyWith(schemaVersion: 2);
    if (next != before) await repository.save(next, isCurrent: current);
    if (!current()) throw const RoomAreaSyncException('account_changed');
    state = AsyncData(next);
  });

  Future<void> addTile(TileConfig tile, {bool Function()? isCurrent}) =>
      _mutate(
        (current) => current.copyWith(tiles: [...current.tiles, tile]),
        isCurrent: isCurrent,
      );
  Future<void> removeTile(String id) => _mutate(
    (current) => current.copyWith(
      tiles: current.tiles.where((t) => t.id != id).toList(),
    ),
  );
  Future<void> updateTile(TileConfig tile) => _mutate(
    (current) => current.copyWith(
      tiles: [
        for (final t in current.tiles)
          if (t.id == tile.id) tile else t,
      ],
    ),
  );

  Future<void> renameEntityReferences(
    String oldId,
    String newId, {
    String? serverUrl,
    bool Function()? isCurrent,
  }) async {
    if (oldId == newId || newId.trim().isEmpty) return;
    final server = serverUrl == null
        ? null
        : normalizedAreaServerUrl(serverUrl);
    List<String> renamed(Iterable<String> ids) =>
        ids.map((id) => id == oldId ? newId : id).toSet().toList();
    await _mutate(
      (current) => current.copyWith(
        rooms: [
          for (final room in current.rooms)
            if (room.areaBinding == null ||
                room.areaBinding!.serverUrl == server)
              _renameReference(room, oldId, newId)
            else
              room,
        ],
        favoriteEntityIds: renamed(current.favoriteEntityIds),
        hiddenEntityIds: renamed(current.hiddenEntityIds),
        entityCardSizes: {
          for (final entry in current.entityCardSizes.entries)
            if (entry.key != oldId) entry.key: entry.value,
          if (current.entityCardSizes.containsKey(oldId) &&
              !current.entityCardSizes.containsKey(newId))
            newId: current.entityCardSizes[oldId]!,
        },
        tiles: [
          for (final tile in current.tiles)
            if (tile.entityId == oldId)
              tile.copyWith(entityId: newId)
            else
              tile,
        ],
      ),
      isCurrent: isCurrent,
    );
  }

  Future<void> setEntityCardSize(String entityId, DashboardCardSize? size) =>
      _mutate(
        (current) => current.copyWith(
          entityCardSizes: {...current.entityCardSizes}
            ..removeWhere((key, _) => key == entityId)
            ..addAll({entityId: ?size}),
        ),
      );

  Future<void> setServiceCardSize(
    AppService service,
    DashboardCardSize? size,
  ) => _mutate(
    (current) => current.copyWith(
      serviceCardSizes: {...current.serviceCardSizes}
        ..remove(service.name)
        ..addAll({service.name: ?size}),
    ),
  );

  Future<void> reorderEntitiesInRoom(String roomId, List<String> orderedIds) {
    final ids = List<String>.unmodifiable(orderedIds);
    return _mutate((current) {
      final room = current.rooms.where((room) => room.id == roomId).firstOrNull;
      if (room == null || !_sameMembers(room.entityIds, ids)) {
        throw const RoomAreaSyncException('layout_changed');
      }
      return current.copyWith(
        rooms: [
          for (final row in current.rooms)
            if (row.id == roomId)
              row.copyWith(
                entityIds: ids,
                areaBinding: row.areaBinding?.copyWith(
                  importedEntityIds: ids.where(
                    row.areaBinding!.importedEntityIds.toSet().contains,
                  ),
                ),
              )
            else
              row,
        ],
      );
    });
  }

  Future<void> reorderTiles(List<String> orderedIds) {
    final ids = List<String>.unmodifiable(orderedIds);
    return _mutate((current) {
      final tiles = {for (final tile in current.tiles) tile.id: tile};
      if (!_sameMembers(tiles.keys.toList(), ids)) {
        throw const RoomAreaSyncException('layout_changed');
      }
      return current.copyWith(tiles: [for (final id in ids) tiles[id]!]);
    });
  }

  Future<void> addRoom(String name) async {
    if (name.trim().isEmpty) return;
    await _mutate(
      (current) => current.copyWith(
        rooms: [
          ...current.rooms,
          DashboardRoom(id: _newId(), name: name.trim()),
        ],
      ),
    );
  }

  Future<void> renameRoom(String roomId, String name) async {
    if (name.trim().isEmpty) return;
    await _mutate(
      (current) => current.copyWith(
        rooms: [
          for (final room in current.rooms)
            if (room.id == roomId) room.copyWith(name: name.trim()) else room,
        ],
      ),
    );
  }

  Future<void> removeRoom(String roomId) => _mutate(
    (current) => current.copyWith(
      rooms: current.rooms.where((room) => room.id != roomId).toList(),
    ),
  );
  Future<void> reorderRooms(int oldIndex, int newIndex) => _mutate((current) {
    final rooms = [...current.rooms];
    if (oldIndex < 0 || oldIndex >= rooms.length) return current;
    final room = rooms.removeAt(oldIndex);
    rooms.insert(newIndex.clamp(0, rooms.length), room);
    return current.copyWith(rooms: rooms);
  });

  Future<void> addEntitiesToRoom(String roomId, Iterable<String> entityIds) {
    final additions = entityIds.where((id) => id.trim().isNotEmpty).toSet();
    return _mutate((current) {
      if (!current.rooms.any((room) => room.id == roomId)) return current;
      return current.copyWith(
        hiddenEntityIds: current.hiddenEntityIds
            .where((id) => !additions.contains(id))
            .toList(),
        rooms: [
          for (final room in current.rooms)
            if (room.id == roomId) _addManual(room, additions) else room,
        ],
      );
    });
  }

  Future<void> removeEntityFromRoom(String roomId, String entityId) => _mutate(
    (current) => current.copyWith(
      rooms: [
        for (final room in current.rooms)
          if (room.id == roomId)
            room.copyWith(
              entityIds: room.entityIds.where((id) => id != entityId).toList(),
              areaBinding: room.areaBinding?.copyWith(
                importedEntityIds: room.areaBinding!.importedEntityIds.where(
                  (id) => id != entityId,
                ),
                excludedEntityIds: {
                  ...room.areaBinding!.excludedEntityIds,
                  entityId,
                },
              ),
            )
          else
            room,
      ],
    ),
  );

  /// Legacy import remains a manual bootstrap and never establishes a binding.
  Future<void> importRooms(Map<String, List<String>> entityIdsByAreaName) {
    final entries = {
      for (final entry in entityIdsByAreaName.entries)
        entry.key.trim(): entry.value.toSet(),
    };
    return _mutate((current) {
      final rooms = [...current.rooms];
      for (final entry in entries.entries) {
        if (entry.value.isEmpty || entry.key.isEmpty) continue;
        final index = rooms.indexWhere(
          (room) => room.name.toLowerCase() == entry.key.toLowerCase(),
        );
        if (index == -1) {
          rooms.add(
            DashboardRoom(
              id: _newId(),
              name: entry.key,
              entityIds: entry.value.toList(),
            ),
          );
        } else {
          rooms[index] = _addManual(rooms[index], entry.value);
        }
      }
      return current.copyWith(rooms: rooms);
    });
  }

  Future<void> detachRoomArea(String roomId) => _mutate(
    (current) => current.copyWith(
      rooms: [
        for (final room in current.rooms)
          if (room.id == roomId) room.copyWith(areaBinding: null) else room,
      ],
    ),
  );

  Future<void> applyAreaSyncChange(
    DashboardLayout expected,
    DashboardRoom nextRoom, {
    required bool Function() isCurrent,
  }) => _mutate((current) {
    if (current != expected) {
      throw const RoomAreaSyncException('layout_changed');
    }
    return current.copyWith(
      rooms: [
        for (final room in current.rooms)
          if (room.id == nextRoom.id) nextRoom else room,
      ],
    );
  }, isCurrent: isCurrent);

  Future<void> toggleFavorite(String entityId) => _mutate(
    (current) => current.copyWith(
      favoriteEntityIds: current.favoriteEntityIds.contains(entityId)
          ? current.favoriteEntityIds.where((id) => id != entityId).toList()
          : [...current.favoriteEntityIds, entityId],
    ),
  );

  Future<void> hideEntity(String entityId) => _mutate((current) {
    if (current.hiddenEntityIds.contains(entityId)) return current;
    return current.copyWith(
      hiddenEntityIds: [...current.hiddenEntityIds, entityId],
      favoriteEntityIds: current.favoriteEntityIds
          .where((id) => id != entityId)
          .toList(),
    );
  });
  Future<void> unhideEntity(String entityId) => _mutate(
    (current) => current.copyWith(
      hiddenEntityIds: current.hiddenEntityIds
          .where((id) => id != entityId)
          .toList(),
    ),
  );

  String _newId() => DateTime.now().microsecondsSinceEpoch.toString();
}

DashboardRoom _addManual(DashboardRoom room, Set<String> additions) =>
    room.copyWith(
      entityIds: {...room.entityIds, ...additions}.toList(),
      areaBinding: room.areaBinding?.copyWith(
        importedEntityIds: room.areaBinding!.importedEntityIds.where(
          (id) => !additions.contains(id),
        ),
        excludedEntityIds: room.areaBinding!.excludedEntityIds.where(
          (id) => !additions.contains(id),
        ),
      ),
    );

DashboardRoom _renameReference(DashboardRoom room, String oldId, String newId) {
  List<String> renamed(Iterable<String> ids) =>
      ids.map((id) => id == oldId ? newId : id).toSet().toList();
  final binding = room.areaBinding;
  final manual = room.entityIds.toSet().difference(
    binding?.importedEntityIds.toSet() ?? {},
  );
  final nextIds = renamed(room.entityIds);
  final nextManual = renamed(manual).toSet();
  return room.copyWith(
    entityIds: nextIds,
    areaBinding: binding?.copyWith(
      importedEntityIds: renamed(binding.importedEntityIds)
          .where((id) => !nextManual.contains(id)),
      excludedEntityIds: renamed(binding.excludedEntityIds)
          .where((id) => !nextIds.contains(id)),
    ),
  );
}

bool _sameMembers(List<String> existing, List<String> ordered) =>
    existing.length == ordered.length &&
    ordered.toSet().length == ordered.length &&
    existing.toSet().containsAll(ordered);
