import 'package:freezed_annotation/freezed_annotation.dart';

import 'tile_config.dart';

part 'dashboard_layout.freezed.dart';
part 'dashboard_layout.g.dart';

@freezed
abstract class DashboardLayout with _$DashboardLayout {
  const factory DashboardLayout({@Default([]) List<TileConfig> tiles}) =
      _DashboardLayout;

  factory DashboardLayout.fromJson(Map<String, dynamic> json) =>
      _$DashboardLayoutFromJson(json);
}
