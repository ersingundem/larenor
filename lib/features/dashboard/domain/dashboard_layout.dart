import 'package:freezed_annotation/freezed_annotation.dart';

import 'dashboard_room.dart';
import 'tile_config.dart';

part 'dashboard_layout.freezed.dart';
part 'dashboard_layout.g.dart';

@freezed
abstract class DashboardLayout with _$DashboardLayout {
  const factory DashboardLayout({
    /// The rooms the user built. The dashboard renders these and nothing
    /// else — an entity appears because it was added to a room, not
    /// because Home Assistant knows about it.
    @Default([]) List<DashboardRoom> rooms,

    /// Hand-added widgets that aren't backed by a Home Assistant entity —
    /// today only websites and history graphs. Everything else on the
    /// dashboard is derived from HA's own area/entity registries rather
    /// than placed by hand, so it needs no [TileConfig].
    @Default([]) List<TileConfig> tiles,
    @Default([]) List<String> favoriteEntityIds,

    /// Entities the user has explicitly hidden from their rooms.
    @Default([]) List<String> hiddenEntityIds,
  }) = _DashboardLayout;

  factory DashboardLayout.fromJson(Map<String, dynamic> json) =>
      _$DashboardLayoutFromJson(json);
}
