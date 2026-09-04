import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/dashboard_repository.dart';
import '../domain/dashboard_layout.dart';
import '../domain/dashboard_room.dart';
import '../domain/tile_config.dart';

part 'dashboard_providers.g.dart';

@riverpod
DashboardRepository dashboardRepository(Ref ref) => DashboardRepository();

@riverpod
class DashboardLayoutNotifier extends _$DashboardLayoutNotifier {
  Future<void> _saveQueue = Future.value();

  @override
  Future<DashboardLayout> build() {
    return ref.watch(dashboardRepositoryProvider).load();
  }

  Future<void> _persist(DashboardLayout layout) async {
    state = AsyncData(layout);
    final repository = ref.read(dashboardRepositoryProvider);
    // Serialize writes: a slower earlier save must not overwrite a newer edit.
    final save = _saveQueue.then((_) => repository.save(layout));
    _saveQueue = save.catchError((Object _) {});
    await save;
  }

  Future<void> addTile(TileConfig tile) async {
    final current = state.value ?? const DashboardLayout();
    await _persist(current.copyWith(tiles: [...current.tiles, tile]));
  }

  Future<void> removeTile(String id) async {
    final current = state.value ?? const DashboardLayout();
    await _persist(
      current.copyWith(tiles: current.tiles.where((t) => t.id != id).toList()),
    );
  }

  Future<void> updateTile(TileConfig tile) async {
    final current = state.value ?? const DashboardLayout();
    await _persist(
      current.copyWith(
        tiles: [
          for (final t in current.tiles)
            if (t.id == tile.id) tile else t,
        ],
      ),
    );
  }

  /// Keep the locally assembled home intact after a registry ID rename.
  Future<void> renameEntityReferences(String oldId, String newId) async {
    if (oldId == newId || newId.trim().isEmpty) return;
    final current = state.value ?? await future;
    List<String> renamed(List<String> ids) =>
        ids.map((id) => id == oldId ? newId : id).toSet().toList();
    await _persist(
      current.copyWith(
        rooms: [
          for (final room in current.rooms)
            room.copyWith(entityIds: renamed(room.entityIds)),
        ],
        favoriteEntityIds: renamed(current.favoriteEntityIds),
        hiddenEntityIds: renamed(current.hiddenEntityIds),
        tiles: [
          for (final tile in current.tiles)
            if (tile.entityId == oldId)
              tile.copyWith(entityId: newId)
            else
              tile,
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Rooms. The dashboard is what the user assembled, so every one of these
  // is an explicit action rather than something derived from the server.
  // ---------------------------------------------------------------------

  Future<void> addRoom(String name) async {
    if (name.trim().isEmpty) return;
    final current = state.value ?? const DashboardLayout();
    final room = DashboardRoom(id: _newId(), name: name.trim());
    await _persist(current.copyWith(rooms: [...current.rooms, room]));
  }

  Future<void> renameRoom(String roomId, String name) async {
    if (name.trim().isEmpty) return;
    final current = state.value ?? const DashboardLayout();
    await _persist(
      current.copyWith(
        rooms: [
          for (final room in current.rooms)
            if (room.id == roomId) room.copyWith(name: name.trim()) else room,
        ],
      ),
    );
  }

  Future<void> removeRoom(String roomId) async {
    final current = state.value ?? const DashboardLayout();
    await _persist(
      current.copyWith(
        rooms: current.rooms.where((room) => room.id != roomId).toList(),
      ),
    );
  }

  Future<void> reorderRooms(int oldIndex, int newIndex) async {
    final current = state.value ?? const DashboardLayout();
    final rooms = [...current.rooms];
    if (oldIndex < 0 || oldIndex >= rooms.length) return;
    final room = rooms.removeAt(oldIndex);
    rooms.insert(newIndex.clamp(0, rooms.length), room);
    await _persist(current.copyWith(rooms: rooms));
  }

  /// Adds several entities at once — picking devices one at a time would
  /// be tedious when setting a room up for the first time. Already-present
  /// ids are skipped rather than duplicated.
  Future<void> addEntitiesToRoom(
    String roomId,
    Iterable<String> entityIds,
  ) async {
    final current = state.value ?? const DashboardLayout();
    if (!current.rooms.any((room) => room.id == roomId)) return;
    final additions = entityIds.where((id) => id.trim().isNotEmpty).toSet();
    await _persist(
      current.copyWith(
        hiddenEntityIds: current.hiddenEntityIds
            .where((id) => !additions.contains(id))
            .toList(),
        rooms: [
          for (final room in current.rooms)
            if (room.id == roomId)
              room.copyWith(
                entityIds: {...room.entityIds, ...additions}.toList(),
              )
            else
              room,
        ],
      ),
    );
  }

  Future<void> removeEntityFromRoom(String roomId, String entityId) async {
    final current = state.value ?? const DashboardLayout();
    await _persist(
      current.copyWith(
        rooms: [
          for (final room in current.rooms)
            if (room.id == roomId)
              room.copyWith(
                entityIds: room.entityIds
                    .where((id) => id != entityId)
                    .toList(),
              )
            else
              room,
        ],
      ),
    );
  }

  /// Bootstraps rooms from Home Assistant's areas — a starting point, not
  /// a binding. Rooms whose name already exists are merged into rather
  /// than duplicated, so importing twice doesn't double everything up.
  Future<void> importRooms(
    Map<String, List<String>> entityIdsByAreaName,
  ) async {
    final current = state.value ?? const DashboardLayout();
    final rooms = [...current.rooms];

    for (final entry in entityIdsByAreaName.entries) {
      final name = entry.key.trim();
      if (entry.value.isEmpty || name.isEmpty) continue;
      final index = rooms.indexWhere(
        (room) => room.name.toLowerCase() == name.toLowerCase(),
      );
      if (index == -1) {
        rooms.add(
          DashboardRoom(
            id: _newId(),
            name: name,
            entityIds: entry.value.toSet().toList(),
          ),
        );
      } else {
        final existing = rooms[index];
        rooms[index] = existing.copyWith(
          entityIds: {...existing.entityIds, ...entry.value}.toList(),
        );
      }
    }

    await _persist(current.copyWith(rooms: rooms));
  }

  String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<void> toggleFavorite(String entityId) async {
    final current = state.value ?? const DashboardLayout();
    final favorites = current.favoriteEntityIds.contains(entityId)
        ? current.favoriteEntityIds.where((id) => id != entityId).toList()
        : [...current.favoriteEntityIds, entityId];
    await _persist(current.copyWith(favoriteEntityIds: favorites));
  }

  /// Hides [entityId] from its room section. Hiding also un-favourites it,
  /// so a hidden entity can't linger at the top of the dashboard.
  Future<void> hideEntity(String entityId) async {
    final current = state.value ?? const DashboardLayout();
    if (current.hiddenEntityIds.contains(entityId)) return;
    await _persist(
      current.copyWith(
        hiddenEntityIds: [...current.hiddenEntityIds, entityId],
        favoriteEntityIds: current.favoriteEntityIds
            .where((id) => id != entityId)
            .toList(),
      ),
    );
  }

  Future<void> unhideEntity(String entityId) async {
    final current = state.value ?? const DashboardLayout();
    await _persist(
      current.copyWith(
        hiddenEntityIds: current.hiddenEntityIds
            .where((id) => id != entityId)
            .toList(),
      ),
    );
  }
}
