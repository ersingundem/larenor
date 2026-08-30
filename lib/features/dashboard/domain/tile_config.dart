import 'package:freezed_annotation/freezed_annotation.dart';

part 'tile_config.freezed.dart';
part 'tile_config.g.dart';

enum TileType { entity, webview }

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
  }) = _TileConfig;

  const TileConfig._();

  factory TileConfig.fromJson(Map<String, dynamic> json) =>
      _$TileConfigFromJson(json);
}
