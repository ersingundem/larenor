import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/dashboard/domain/core_keenetic_tile_validation.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout_validation.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/core_keenetic_tile.dart';
import 'package:larenor/features/dashboard/presentation/tiles/tile_registry.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const resource = '33333333333333333333333333333333';
const binding = '44444444444444444444444444444444';

Map<String, dynamic> tile([Map<String, dynamic> change = const {}]) => {
  'id': 'core-router',
  'type': 'coreKeenetic',
  'x': 0,
  'y': 0,
  'width': 3,
  'height': 2,
  'title': 'Main router',
  'coreId': core,
  'coreHomeId': home,
  'coreResourceId': resource,
  'coreResourceRevision': 7,
  'coreResourceAclRevision': 9,
  'coreBindingId': binding,
  'coreBindingRevision': 4,
  ...change,
};

Map<String, dynamic> layout(Map<String, dynamic> value) => {
  'schemaVersion': 2,
  'rooms': [],
  'tiles': [value],
};

Map<String, dynamic> backup(Map<String, dynamic> value) => {
  'version': 1,
  'createdAt': '2026-09-10T00:00:00Z',
  'groups': {'dashboard': value},
};

void main() {
  test('Core resource and binding revisions survive layout and backup', () {
    final raw = layout(tile());
    validateDashboardLayoutJson(raw);
    final decoded = DashboardLayout.fromJson(raw);
    expect(decoded.tiles.single.type, TileType.coreKeenetic);
    expect(decoded.tiles.single.coreResourceRevision, 7);
    expect(decoded.tiles.single.coreResourceAclRevision, 9);
    expect(decoded.tiles.single.coreBindingRevision, 4);
    final roundTrip = jsonDecode(jsonEncode(decoded.toJson()));
    expect(DashboardLayout.fromJson(roundTrip), decoded);
    expect(BackupSnapshot.fromJson(backup(roundTrip)).hasDashboard, isTrue);
    expect(buildTileContent(decoded.tiles.single), isA<CoreKeeneticTile>());
  });

  for (final entry in <String, Map<String, dynamic>>{
    'missing binding': {'coreBindingId': null},
    'missing resource revision': {'coreResourceRevision': null},
    'zero ACL revision': {'coreResourceAclRevision': 0},
    'negative binding revision': {'coreBindingRevision': -1},
    'wrong resource id': {'coreResourceId': 'not-an-id'},
    'foreign field': {'keeneticMetric': 'internetStatus'},
    'direct tile injection': {'type': 'keenetic'},
    'entity injection': {'entityId': 'button.unlock'},
    'URL injection': {'url': 'https://router.invalid'},
  }.entries) {
    test('Core tile validators reject ${entry.key}', () {
      final value = tile(entry.value);
      expect(hasValidCoreKeeneticTileFields(value), isFalse);
      expect(
        () => validateDashboardLayoutJson(layout(value)),
        throwsFormatException,
      );
      expect(
        () => BackupSnapshot.fromJson(backup(layout(value))),
        throwsA(isA<BackupValidationException>()),
      );
    });
  }
}
