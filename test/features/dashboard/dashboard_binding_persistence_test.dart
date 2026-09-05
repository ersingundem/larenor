import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout_validation.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/ha_area_binding.dart';

Map<String, dynamic> _binding() => {
  'serverUrl': 'http://ha.test',
  'areaId': 'salon',
  'sourceName': 'Salon',
  'importedEntityIds': ['light.imported'],
  'excludedEntityIds': ['light.excluded'],
};
Map<String, dynamic> _layout({Map<String, dynamic>? binding}) => {
  'schemaVersion': 2,
  'rooms': [
    {
      'id': 'room',
      'name': 'Salon',
      'entityIds': ['light.imported', 'light.manual'],
      'areaBinding': binding ?? _binding(),
    },
  ],
  'favoriteEntityIds': ['light.manual'],
  'hiddenEntityIds': ['light.imported'],
  'tiles': [],
};
Map<String, dynamic> _backup(Map<String, dynamic> layout) => {
  'version': 1,
  'createdAt': '2026-09-05T00:00:00Z',
  'groups': {'dashboard': layout},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('legacy layout roundtrips as unbound without network migration', () async {
    const legacy =
        '{"rooms":[{"id":"room","name":"Old","entityIds":["light.old"]}],"tiles":[]}';
    SharedPreferences.setMockInitialValues({'dashboard_layout': legacy});
    final repository = DashboardRepository();
    final result = await repository.load();
    expect(result.rooms.single.areaBinding, isNull);
    expect(result.rooms.single.entityIds, ['light.old']);
    await repository.save(result);
    expect(await repository.load(), result);
  });

  test('binding provenance is immutable and survives local JSON and backup roundtrip', () async {
    final decoded = _layout();
    final value = DashboardLayout.fromJson(decoded);
    expect(
      () => value.rooms.single.areaBinding!.importedEntityIds.add('light.bad'),
      throwsUnsupportedError,
    );
    expect(
      DashboardLayout.fromJson(
        jsonDecode(jsonEncode(value.toJson())) as Map<String, dynamic>,
      ),
      value,
    );
    await DashboardRepository().save(value);
    expect(await DashboardRepository().load(), value);
    final backup = BackupSnapshot.fromJson(_backup(decoded));
    expect(backup.hasDashboard, isTrue);
  });

  final invalidBindings = <String, Map<String, dynamic>>{
    'embedded token': {..._binding(), 'token': 'fixture-sensitive'},
    'URL credentials': {
      ..._binding(),
      'serverUrl': 'http://user:fixture@ha.test',
    },
    'URL query': {..._binding(), 'serverUrl': 'http://ha.test?token=fixture'},
    'noncanonical server URL': {..._binding(), 'serverUrl': 'http://ha.test/'},
    'wrong URL scheme': {..._binding(), 'serverUrl': 'file:///private/fixture'},
    'unknown property': {..._binding(), 'syncAutomatically': true},
    'duplicate imported': {
      ..._binding(),
      'importedEntityIds': ['light.imported', 'light.imported'],
    },
    'imported and excluded': {
      ..._binding(),
      'excludedEntityIds': ['light.imported'],
    },
    'missing required provenance': {..._binding()}..remove('importedEntityIds'),
    'invalid ID': {
      ..._binding(),
      'excludedEntityIds': ['light.bad/../path'],
    },
    'imported not a room member': {
      ..._binding(),
      'importedEntityIds': ['light.other'],
    },
    'excluded still a room member': {
      ..._binding(),
      'excludedEntityIds': ['light.manual'],
    },
  };
  for (final entry in invalidBindings.entries) {
    test('local and backup validators reject ${entry.key}', () {
      final value = _layout(binding: entry.value);
      expect(() => validateDashboardLayoutJson(value), throwsFormatException);
      expect(
        () => BackupSnapshot.fromJson(_backup(value)),
        throwsA(isA<BackupValidationException>()),
      );
    });
  }

  test('unsupported future schema is not loaded or overwritten', () async {
    final raw = jsonEncode({..._layout(), 'schemaVersion': 99});
    SharedPreferences.setMockInitialValues({'dashboard_layout': raw});
    await expectLater(DashboardRepository().load(), throwsFormatException);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('dashboard_layout'), raw);
    expect(
      () =>
          BackupSnapshot.fromJson(_backup({..._layout(), 'schemaVersion': 99})),
      throwsA(isA<BackupValidationException>()),
    );
  });

  test(
    'oversized persisted blob rejects before decoding without replacing it',
    () async {
      final raw = ' ' * (maxDashboardLayoutBytes + 1);
      SharedPreferences.setMockInitialValues({'dashboard_layout': raw});
      await expectLater(DashboardRepository().load(), throwsFormatException);
      expect(
        (await SharedPreferences.getInstance()).getString('dashboard_layout'),
        raw,
      );
    },
  );

  test(
    'account guard rejects queued save before touching local preferences',
    () async {
      final repository = DashboardRepository();
      await expectLater(
        repository.save(const DashboardLayout(), isCurrent: () => false),
        throwsStateError,
      );
      expect(
        (await SharedPreferences.getInstance()).containsKey('dashboard_layout'),
        isFalse,
      );
    },
  );

  test('binding without token has redacted string representation', () {
    final binding = HaAreaBinding.fromJson(_binding());
    expect(binding.toString(), isNot(contains('ha.test')));
    expect(
      binding.toJson().keys,
      unorderedEquals([
        'serverUrl',
        'areaId',
        'sourceName',
        'importedEntityIds',
        'excludedEntityIds',
      ]),
    );
    expect(
      DashboardRoom(id: 'id', name: 'Salon', areaBinding: binding).areaBinding,
      binding,
    );
  });
}
