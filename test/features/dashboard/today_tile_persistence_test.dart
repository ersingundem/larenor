import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout_validation.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';

Map<String, dynamic> _layout({
  String type = 'today',
  Object? section = 'calendar',
  Object? query = 'dentist',
}) => {
  'schemaVersion': 2,
  'rooms': <Object>[],
  'tiles': [
    {
      'id': 'today',
      'type': type,
      'x': 0,
      'y': 0,
      'width': 3,
      'height': 2,
      'todaySection': ?section,
      'todayQuery': ?query,
    },
  ],
  'favoriteEntityIds': <Object>[],
  'hiddenEntityIds': <Object>[],
  'entityCardSizes': <String, Object>{},
  'serviceCardSizes': <String, Object>{},
};

void main() {
  test(
    'Today section and bounded filter survive validated JSON round-trip',
    () {
      const layout = DashboardLayout(
        tiles: [
          TileConfig(
            id: 'today',
            type: TileType.today,
            x: 0,
            y: 0,
            width: 3,
            height: 2,
            todaySection: 'calendar',
            todayQuery: 'dentist',
          ),
        ],
      );
      final json = jsonDecode(jsonEncode(layout.toJson()));
      expect(() => validateDashboardLayoutJson(json), returnsNormally);
      expect(
        () => BackupSnapshot.fromJson({
          'version': 1,
          'createdAt': '2026-09-11T00:00:00Z',
          'groups': {'dashboard': json},
        }),
        returnsNormally,
      );
      expect(DashboardLayout.fromJson(json).tiles.single, layout.tiles.single);
    },
  );

  test('invalid or cross-type Today preferences fail closed', () {
    for (final value in <Map<String, dynamic>>[
      _layout(section: 'unknown'),
      _layout(section: 1),
      _layout(query: List.filled(129, 'x').join()),
      _layout(query: 'private\nvalue'),
      _layout(type: 'history'),
    ]) {
      expect(() => validateDashboardLayoutJson(value), throwsFormatException);
      expect(
        () => BackupSnapshot.fromJson({
          'version': 1,
          'createdAt': '2026-09-11T00:00:00Z',
          'groups': {'dashboard': value},
        }),
        throwsA(isA<BackupValidationException>()),
      );
    }
  });
}
