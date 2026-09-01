import 'package:freezed_annotation/freezed_annotation.dart';

import 'tile_config.dart';

part 'dashboard_layout.freezed.dart';
part 'dashboard_layout.g.dart';

@freezed
abstract class DashboardLayout with _$DashboardLayout {
  const factory DashboardLayout({
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
