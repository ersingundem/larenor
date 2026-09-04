import 'package:freezed_annotation/freezed_annotation.dart';

part 'dashboard_room.freezed.dart';
part 'dashboard_room.g.dart';

/// A room the user built themselves.
///
/// Deliberately *not* tied to Home Assistant's area registry. Deriving the
/// dashboard from HA areas put every entity HA knows about on screen,
/// which on a real server is hundreds of rows of diagnostic noise. Areas
/// are still useful as a starting point, so they can be imported — but
/// after that the rooms are the user's, and adding a device is an explicit
/// choice rather than something that happens because HA knows about it.
@freezed
abstract class DashboardRoom with _$DashboardRoom {
  const factory DashboardRoom({
    required String id,
    required String name,

    /// Ordered — the user's arrangement, not HA's.
    @Default([]) List<String> entityIds,
  }) = _DashboardRoom;

  const DashboardRoom._();

  factory DashboardRoom.fromJson(Map<String, dynamic> json) =>
      _$DashboardRoomFromJson(json);

  bool get isEmpty => entityIds.isEmpty;
}
