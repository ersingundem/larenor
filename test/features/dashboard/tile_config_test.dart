import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';

void main() {
  test('DashboardLayout survives a JSON-string round trip', () {
    const layout = DashboardLayout(
      tiles: [
        TileConfig(
          id: '1',
          type: TileType.entity,
          x: 0,
          y: 0,
          width: 2,
          height: 2,
          entityId: 'light.kitchen',
        ),
        TileConfig(
          id: '2',
          type: TileType.webview,
          x: 2,
          y: 0,
          width: 4,
          height: 4,
          url: 'https://example.com',
        ),
      ],
      favoriteEntityIds: ['light.kitchen', 'scene.movie_night'],
    );

    final roundTripped = DashboardLayout.fromJson(
      jsonDecode(jsonEncode(layout.toJson())) as Map<String, dynamic>,
    );

    expect(roundTripped, layout);
  });

  test('new tile types round-trip through JSON', () {
    const layout = DashboardLayout(
      tiles: [
        TileConfig(
          id: '1',
          type: TileType.scene,
          x: 0,
          y: 0,
          width: 2,
          height: 2,
          entityId: 'scene.movie_night',
        ),
        TileConfig(
          id: '2',
          type: TileType.mediaPlayer,
          x: 0,
          y: 2,
          width: 3,
          height: 3,
          entityId: 'media_player.living_room',
        ),
        TileConfig(
          id: '3',
          type: TileType.climate,
          x: 3,
          y: 2,
          width: 3,
          height: 3,
          entityId: 'climate.thermostat',
        ),
        TileConfig(
          id: '4',
          type: TileType.weather,
          x: 0,
          y: 5,
          width: 4,
          height: 3,
          entityId: 'weather.home',
        ),
        TileConfig(
          id: '5',
          type: TileType.history,
          x: 4,
          y: 5,
          width: 4,
          height: 3,
          entityId: 'sensor.temperature',
        ),
        TileConfig(
          id: '6',
          type: TileType.camera,
          x: 8,
          y: 5,
          width: 3,
          height: 3,
          entityId: 'camera.front_door',
        ),
      ],
    );

    final roundTripped = DashboardLayout.fromJson(
      jsonDecode(jsonEncode(layout.toJson())) as Map<String, dynamic>,
    );

    expect(roundTripped, layout);
  });

  test('service-widget tile types round-trip with no entityId needed', () {
    const layout = DashboardLayout(
      tiles: [
        TileConfig(
          id: '1',
          type: TileType.jellyfin,
          x: 0,
          y: 0,
          width: 3,
          height: 2,
        ),
        TileConfig(
          id: '2',
          type: TileType.proxmox,
          x: 3,
          y: 0,
          width: 3,
          height: 2,
        ),
        TileConfig(
          id: '3',
          type: TileType.keenetic,
          x: 6,
          y: 0,
          width: 3,
          height: 2,
        ),
      ],
    );

    final roundTripped = DashboardLayout.fromJson(
      jsonDecode(jsonEncode(layout.toJson())) as Map<String, dynamic>,
    );

    expect(roundTripped, layout);
  });
}
