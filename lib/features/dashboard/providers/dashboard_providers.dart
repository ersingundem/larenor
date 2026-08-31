import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/dashboard_repository.dart';
import '../domain/dashboard_layout.dart';
import '../domain/tile_config.dart';

part 'dashboard_providers.g.dart';

@riverpod
DashboardRepository dashboardRepository(Ref ref) => DashboardRepository();

@riverpod
class DashboardLayoutNotifier extends _$DashboardLayoutNotifier {
  @override
  Future<DashboardLayout> build() {
    return ref.watch(dashboardRepositoryProvider).load();
  }

  Future<void> _persist(DashboardLayout layout) async {
    state = AsyncData(layout);
    await ref.read(dashboardRepositoryProvider).save(layout);
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

  Future<void> toggleFavorite(String entityId) async {
    final current = state.value ?? const DashboardLayout();
    final favorites = current.favoriteEntityIds.contains(entityId)
        ? current.favoriteEntityIds.where((id) => id != entityId).toList()
        : [...current.favoriteEntityIds, entityId];
    await _persist(current.copyWith(favoriteEntityIds: favorites));
  }
}
