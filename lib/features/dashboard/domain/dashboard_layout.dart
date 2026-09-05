import 'package:freezed_annotation/freezed_annotation.dart';

import 'dashboard_room.dart';
import 'dashboard_card_size.dart';
import 'tile_config.dart';

part 'dashboard_layout.freezed.dart';
part 'dashboard_layout.g.dart';

@freezed
abstract class DashboardLayout with _$DashboardLayout {
  // Freezed forwards this constructor annotation to its generated class.
  // ignore: invalid_annotation_target
  @JsonSerializable(explicitToJson: true)
  const factory DashboardLayout({
    @Default(2) int schemaVersion,

    /// The rooms the user built. The dashboard renders these and nothing
    /// else — an entity appears because it was added to a room, not
    /// because Home Assistant knows about it.
    @Default([]) List<DashboardRoom> rooms,

    /// Explicit user cards; their ordered list is independent of HA registry
    /// membership and is preserved by room synchronization.
    @Default([]) List<TileConfig> tiles,
    @Default([]) List<String> favoriteEntityIds,

    /// Entities the user has explicitly hidden from their rooms.
    @Default([]) List<String> hiddenEntityIds,

    /// Overrides only; an absent entry uses the responsive UI default.
    @Default({}) Map<String, DashboardCardSize> entityCardSizes,
    @Default({}) Map<String, DashboardCardSize> serviceCardSizes,
  }) = _DashboardLayout;

  factory DashboardLayout.fromJson(Map<String, dynamic> json) =>
      _$DashboardLayoutFromJson(json);
}
