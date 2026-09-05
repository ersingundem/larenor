import 'package:freezed_annotation/freezed_annotation.dart';

import '../../keenetic/domain/keenetic_metric.dart';
import '../../web_panel/domain/web_panel_options.dart';

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
  // Freezed forwards this constructor annotation to its generated class.
  // ignore: invalid_annotation_target
  @JsonSerializable(explicitToJson: true)
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
    WebPanelOptions? webPanel,
  }) = _TileConfig;

  const TileConfig._();

  factory TileConfig.fromJson(Map<String, dynamic> json) =>
      _$TileConfigFromJson(json);
}
