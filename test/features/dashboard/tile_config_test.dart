import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/dashboard/domain/dashboard_layout.dart';
import 'package:oikos/features/dashboard/domain/tile_config.dart';

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
    );

    final roundTripped = DashboardLayout.fromJson(
      jsonDecode(jsonEncode(layout.toJson())) as Map<String, dynamic>,
    );

    expect(roundTripped, layout);
  });
}
