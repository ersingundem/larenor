import 'package:freezed_annotation/freezed_annotation.dart';

import 'ha_area_binding.dart';

part 'dashboard_room.freezed.dart';
part 'dashboard_room.g.dart';

/// A user-owned room with ordered manual membership. An optional, explicit
/// HA area binding proposes local changes only after a reviewed preview.
/// Legacy/imported rooms remain unbound until the user chooses a binding.
@freezed
abstract class DashboardRoom with _$DashboardRoom {
  // Freezed forwards this constructor annotation to its generated class.
  // ignore: invalid_annotation_target
  @JsonSerializable(explicitToJson: true)
  const factory DashboardRoom({
    required String id,
    required String name,

    /// Ordered — the user's arrangement, not HA's.
    @Default([]) List<String> entityIds,
    HaAreaBinding? areaBinding,
  }) = _DashboardRoom;

  const DashboardRoom._();

  factory DashboardRoom.fromJson(Map<String, dynamic> json) =>
      _$DashboardRoomFromJson(json);

  bool get isEmpty => entityIds.isEmpty;
}
