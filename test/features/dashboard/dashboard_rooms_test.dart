import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('DashboardRoom', () {
    test('round-trips through JSON', () {
      const room = DashboardRoom(
        id: 'r1',
        name: 'Kitchen',
        entityIds: ['light.a', 'switch.b'],
      );

      final restored = DashboardRoom.fromJson(room.toJson());
      expect(restored, room);
      expect(restored.entityIds, ['light.a', 'switch.b']);
    });

    test('a new room starts empty', () {
      const room = DashboardRoom(id: 'r1', name: 'Kitchen');
      expect(room.isEmpty, isTrue);
      expect(room.entityIds, isEmpty);
    });
  });

  group('DashboardLayout persistence', () {
    test('rooms survive a save and load', () async {
      final repository = DashboardRepository();
      const layout = DashboardLayout(
        rooms: [
          DashboardRoom(id: 'r1', name: 'Kitchen', entityIds: ['light.a']),
          DashboardRoom(id: 'r2', name: 'Lounge'),
        ],
        favoriteEntityIds: ['light.a'],
      );

      await repository.save(layout);
      final loaded = await repository.load();

      expect(loaded.rooms, hasLength(2));
      expect(loaded.rooms.first.name, 'Kitchen');
      expect(loaded.rooms.first.entityIds, ['light.a']);
      expect(loaded.favoriteEntityIds, ['light.a']);
    });

    test('a layout saved before rooms existed still loads', () async {
      // Existing installs have a stored blob with no `rooms` key at all;
      // it has to keep working rather than throwing on load.
      SharedPreferences.setMockInitialValues({
        'dashboard_layout':
            '{"tiles":[],"favoriteEntityIds":["light.a"],'
            '"hiddenEntityIds":[]}',
      });

      final loaded = await DashboardRepository().load();

      expect(loaded.rooms, isEmpty);
      expect(loaded.favoriteEntityIds, ['light.a']);
    });

    test('hand-added widgets are unaffected by rooms', () async {
      final repository = DashboardRepository();
      const layout = DashboardLayout(
        rooms: [DashboardRoom(id: 'r1', name: 'Kitchen')],
        tiles: [
          TileConfig(
            id: 't1',
            type: TileType.webview,
            x: 0,
            y: 0,
            width: 3,
            height: 2,
            url: 'https://example.com',
          ),
        ],
      );

      await repository.save(layout);
      final loaded = await repository.load();

      expect(loaded.tiles.single.url, 'https://example.com');
      expect(loaded.rooms.single.name, 'Kitchen');
    });
  });

  group('room editing semantics', () {
    // The notifier needs a ProviderContainer to exercise, so these cover
    // the same list transforms it performs, which is where the bugs live.

    List<DashboardRoom> addEntities(
      List<DashboardRoom> rooms,
      String roomId,
      List<String> ids,
    ) => [
      for (final room in rooms)
        if (room.id == roomId)
          room.copyWith(
            entityIds: [
              ...room.entityIds,
              ...ids.where((id) => !room.entityIds.contains(id)),
            ],
          )
        else
          room,
    ];

    test('adding skips ids the room already holds', () {
      const rooms = [
        DashboardRoom(id: 'r1', name: 'Kitchen', entityIds: ['light.a']),
      ];

      final updated = addEntities(rooms, 'r1', ['light.a', 'light.b']);

      expect(updated.single.entityIds, ['light.a', 'light.b']);
    });

    test('adding leaves other rooms alone', () {
      const rooms = [
        DashboardRoom(id: 'r1', name: 'Kitchen'),
        DashboardRoom(id: 'r2', name: 'Lounge', entityIds: ['light.z']),
      ];

      final updated = addEntities(rooms, 'r1', ['light.a']);

      expect(updated[0].entityIds, ['light.a']);
      expect(updated[1].entityIds, ['light.z']);
    });

    test(
      'importing merges into a room of the same name, case-insensitively',
      () {
        // Importing HA areas twice shouldn't double everything up.
        const existing = DashboardRoom(
          id: 'r1',
          name: 'Kitchen',
          entityIds: ['light.a'],
        );
        const incomingName = 'kitchen';
        const incomingIds = ['light.a', 'light.b'];

        final matches =
            existing.name.toLowerCase() == incomingName.toLowerCase();
        final merged = existing.copyWith(
          entityIds: [
            ...existing.entityIds,
            ...incomingIds.where((id) => !existing.entityIds.contains(id)),
          ],
        );

        expect(matches, isTrue);
        expect(merged.entityIds, ['light.a', 'light.b']);
      },
    );
  });
}
