import 'package:freezed_annotation/freezed_annotation.dart';

import '../../keenetic/domain/keenetic_metric.dart';

part 'tile_config.freezed.dart';
part 'tile_config.g.dart';

enum TileType {
  entity,
  webview,
  scene,
  mediaPlayer,
  climate,
  weather,
  history,
  camera,
  jellyfin,
  jellyseerr,
  sonarr,
  radarr,
  lidarr,
  readarr,
  bazarr,
  prowlarr,
  qbittorrent,
  proxmox,
  keenetic,
}

@freezed
abstract class TileConfig with _$TileConfig {
  const factory TileConfig({
    required String id,
    required TileType type,
    required int x,
    required int y,
    required int width,
    required int height,
    String? entityId,
    String? url,
    String? title,
    KeeneticMetricKind? keeneticMetric,
    String? keeneticInterfaceId,
  }) = _TileConfig;

  const TileConfig._();

  factory TileConfig.fromJson(Map<String, dynamic> json) =>
      _$TileConfigFromJson(json);
}
