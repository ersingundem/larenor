import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout_validation.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/home_resources/domain/core_resource_binding.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';

const _roomBinding = CoreResourceBinding(
  coreId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  homeId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  resourceId: 'cccccccccccccccccccccccccccccccc',
  kind: HomeResourceKind.room,
  resourceRevision: 2,
  aclRevision: 3,
  userRevision: 4,
);
const _cardBinding = CoreResourceBinding(
  coreId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  homeId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  resourceId: 'dddddddddddddddddddddddddddddddd',
  kind: HomeResourceKind.resource,
  resourceRevision: 5,
  aclRevision: 6,
  userRevision: 7,
);

Map<String, dynamic> _backup(Map<String, dynamic> dashboard) => {
  'version': 1,
  'createdAt': '2026-09-24T00:00:00Z',
  'groups': {'dashboard': dashboard},
};

Map<String, dynamic> _layout() => jsonDecode(
  jsonEncode(
    const DashboardLayout(
      rooms: [
        DashboardRoom(
          id: 'room',
          name: 'Living room',
          coreResource: _roomBinding,
        ),
      ],
      tiles: [
        TileConfig(
          id: 'resource',
          type: TileType.coreResource,
          x: 0,
          y: 0,
          width: 3,
          height: 2,
          coreResource: _cardBinding,
        ),
      ],
    ).toJson(),
  ),
) as Map<String, dynamic>;

void main() {
  test('Core room and card bindings survive portable backup validation', () {
    final layout = _layout();
    expect(() => validateDashboardLayoutJson(layout), returnsNormally);
    expect(BackupSnapshot.fromJson(_backup(layout)).hasDashboard, isTrue);
  });

  for (final mutation in <String, void Function(Map<String, dynamic>)>{
    'unknown binding field': (layout) {
      final room = (layout['rooms'] as List).single as Map<String, dynamic>;
      (room['coreResource'] as Map<String, dynamic>)['token'] = 'forbidden';
    },
    'room binding with resource kind': (layout) {
      final room = (layout['rooms'] as List).single as Map<String, dynamic>;
      (room['coreResource'] as Map<String, dynamic>)['kind'] = 'resource';
    },
    'card binding with room kind': (layout) {
      final tile = (layout['tiles'] as List).single as Map<String, dynamic>;
      (tile['coreResource'] as Map<String, dynamic>)['kind'] = 'room';
    },
    'out-of-range revision': (layout) {
      final tile = (layout['tiles'] as List).single as Map<String, dynamic>;
      (tile['coreResource'] as Map<String, dynamic>)['aclRevision'] = 0;
    },
  }.entries) {
    test('local and backup validators reject ${mutation.key}', () {
      final layout = _layout();
      mutation.value(layout);
      expect(() => validateDashboardLayoutJson(layout), throwsFormatException);
      expect(
        () => BackupSnapshot.fromJson(_backup(layout)),
        throwsA(isA<BackupValidationException>()),
      );
    });
  }
}
