import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('load returns an empty layout when nothing is saved', () async {
    final layout = await DashboardRepository().load();
    expect(layout.tiles, isEmpty);
  });

  test('save then load round-trips the layout', () async {
    final repository = DashboardRepository();
    const layout = DashboardLayout(
      tiles: [
        TileConfig(
          id: '1',
          type: TileType.entity,
          x: 0,
          y: 0,
          width: 2,
          height: 2,
          entityId: 'switch.fan',
        ),
      ],
    );

    await repository.save(layout);
    final loaded = await repository.load();

    expect(loaded, layout);
  });
}
